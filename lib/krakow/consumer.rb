module Krakow
  class Consumer

    include Utils::Lazy
    include Celluloid

    trap_exit :connection_failure
    finalizer :goodbye_my_love!

    attr_reader :connections, :discovery, :distribution, :queue

    def initialize(args={})
      super
      required! :topic, :channel
      optional :host, :port, :nslookupd, :max_in_flight
      arguments[:max_in_flight] ||= 1
      @connections = {}
      @distribution = Distribution::Default.new(
        :max_in_flight => max_in_flight
      )
      @queue = Queue.new
      if(nslookupd)
        debug "Connections will be established via lookup #{nslookupd.inspect}"
        @discovery = Discovery.new(:nslookupd => nslookupd)
        every(60){ init! }
        init!
      elsif(host && port)
        debug "Connection will be established via direct connection #{host}:#{port}"
        connection = build_connection(host, port, queue)
        if(register(connection))
          info "Registered new connection #{connection}"
          distribution.redistribute!
        else
          abort ConnectionFailure.new("Failed to establish subscription at provided end point (#{host}:#{port}")
        end
      else
        abort ConfigurationError.new('No connection information provided!')
      end
    end

    def to_s
      "<#{self.class.name}:#{object_id} T:#{topic} C:#{channel}>"
    end

    def goodbye_my_love!
      debug 'Tearing down consumer'
      connections.values.each do |con|
        con.terminate if con.alive?
      end
      distribution.terminate if distribution && distribution.alive?
      info 'Consumer torn down'
    end

    # host:: remote address
    # port:: remote port
    # queue:: message store queue
    # Build new `Connection`
    def build_connection(host, port, queue)
      connection = Connection.new(
        :host => host,
        :port => port,
        :queue => queue,
        :callback => {
          :actor => current_actor,
          :method => :process_message
        }
      )
    end

    # message:: FrameType
    # connection:: Connection
    # Process message if required
    def process_message(message, connection)
      if(message.is_a?(FrameType::Message))
        distribution.register_message(message, connection)
      end
      message
    end

    # connection:: Connection
    # Send RDY for connection based on distribution rules
    def update_ready!(connection)
      distribution.set_ready_for(connection)
    end

    # Requests lookup and adds connections
    def init!
      debug 'Running consumer `init!` connection builds'
      found = discovery.lookup(topic)
      debug "Discovery results: #{found.inspect}"
      connection = nil
      found.each do |node|
        debug "Processing discovery result: #{node.inspect}"
        key = "#{node[:broadcast_address]}_#{node[:tcp_port]}"
        unless(connections[key])
          connection = build_connection(node[:broadcast_address], node[:tcp_port], queue)
          info "Registered new connection #{connection}" if register(connection)
        else
          debug "Discovery result already registered: #{node.inspect}"
        end
      end
      distribution.redistribute! if connection
    end

    # connection:: Connection
    # Registers connection with subscription. Returns false if failed
    def register(connection)
      begin
        connection.init!
        connection.transmit(Command::Sub.new(:topic_name => topic, :channel_name => channel))
        self.link connection
        connections["#{connection.host}_#{connection.port}"] = connection
        distribution.add_connection(connection)
        true
      rescue Error::BadResponse => e
        debug "Failed to establish connection: #{e.result.error}"
        connection.terminate
        false
      end
    end

    # con:: actor
    # reason:: Exception
    # Remove connection from register if found
    def connection_failure(con, reason)
      connections.delete_if do |key, value|
        if(value == con)
          warn "Connection failure detected. Removing connection: #{key}"
          discovery.remove_connection(con)
          true
        end
      end
    end

    # message_id:: Message ID
    # Confirm message has been processed
    def confirm(message_id)
      distribution.in_flight_lookup(message_id) do |connection|
        connection.transmit(Command::Fin.new(:message_id => message_id))
      end
      connection = distribution.unregister_message(message_id)
      update_ready!(connection)
      true
    end

    # message_id:: Message ID
    # timeout:: Requeue timeout (default is none)
    # Requeue message (processing failure)
    def requeue(message_id, timeout=0)
      distribution.in_flight_lookup(message_id) do |connection|
        connection.transmit(
          Command::Req.new(
            :message_id => message_id,
            :timeout => timeout
          )
        )
      end
      connection = distributrion.unregister_message(message_id)
      update_ready!(connection)
      true
    end

  end
end
