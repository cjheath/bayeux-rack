#
# A Bayeux (COMET) server using Async Sinatra.
# This requires a web server built on EventMachine, such as Thin.
#
# Copyright: Clifford Heath http://dataconstellation.com 2011
# License: MIT
#
require 'sinatra'
require 'sinatra/async'
require 'json'
require 'eventmachine'

# A Sinatra application that handles PUTs and POSTs on the /cometd URL,
# implementing the COMET protocol.
class Bayeux < Sinatra::Base
  # The Gem version of this implementation
  VERSION = "0.6.1"
  register Sinatra::Async

  # A connected client
  class Client
    # The clientId we assigned
    attr_accessor :clientId

    # Timestamp when we last had activity from this client
    #attr_accessor :lastSeen

    # The EM::Channel on which this client subscribes
    attr_accessor :channel

    # The EM::Subscription a long-poll is currently active
    attr_accessor :subscription

    # Messages queued for this client (an Array)
    attr_accessor :queue

    # Array of channels this client is subscribed to
    attr_accessor :channels

    def initialize clientId     #:nodoc:
      @clientId = clientId
      @channel = EM::Channel.new
      @queue = []
      @channels = []
    end

    def flush sinatra           #:nodoc:
      queued = @queue
      sinatra.trace "Sending to #{@clientId}: #{queued.inspect}"
      @queue = []

      sinatra.respond(queued)
    end
  end

  enable :show_exceptions

  # Perhaps some initialisation here in future?
  #def initialize *a, &b
  #  super
  #end

  configure do
    set :tracing, false         # Enable to get Bayeux tracing
    set :poll_interval, 5       # 5 seconds for polling
    set :long_poll_interval, 30 # maximum duration for a long-poll
  end

  # Trace to stdout if the :tracing setting is enabled
  def trace s
    if settings.tracing
      puts s
    end
  end

  # A Hash of channels by channel name. Each channel is an Array of subscribed clients
  def channels
    # Sinatra dup's this object, so we have to use class variables
    @@channels ||= Hash.new {|h, k| h[k] = [] }
  end

  # A Hash of all clients by clientId
  def clients
    @@clients ||= {}
  end

  # ClientIds should be strong random numbers containing at least 128 bits of entropy. These aren't!
  def next_client_id
    begin
      id = (rand*1_000_000_000).to_i
    end until !clients[id]
    trace "New client recieves ID #{id}"
    id
  end

  # Send a message (a Hash) to a channel.
  # The message must have the channel name under the key :channel or "channel"
  def publish message
    channel = message['channel'] || message[:channel]
    clients = channels[channel]
    trace "publishing to #{channel} with #{clients.size} subscribers: #{message.inspect}"
    clients.each do | client|
      client.queue << message
      client.channel.push true    # Wake up the subscribed client
    end
  end

  # Handle a request from a client. Normally over-ridden in the subclass to add server behaviour.
  def deliver(message)
    id = message['id']
    clientId = message['clientId']
    channel_name = message['channel']

    response =
      case channel_name
      when '/meta/handshake'      # Client says hello, greet them
        clientId = next_client_id
        clients[clientId] = Client.new(clientId)
        trace "Client #{clientId} offers a handshake from #{request.ip}"
        handshake message

      when '/meta/subscribe'      # Client wants to subscribe to a channel:
        subscribe message

      when '/meta/unsubscribe'    # Client wants to unsubscribe from a channel:
        unsubscribe message

      # This is the long-polling request.
      when '/meta/connect'
        connect message

      when '/meta/disconnect'
        disconnect message

      # Other meta channels are disallowed
      when %r{/meta/(.*)}
        trace "Client #{clientId} tried to send a message to #{channel_name}"
        { :successful => false }

      # Service channels default to no-op. Service messages are never broadcast.
      when %r{/service/(.*)}
        trace "Client #{clientId} sent a private message to #{channel_name}"
        { :successful => true }

      else
        puts "Unknown channel in request: "+message.inspect
        pass  # 404
      end

    # Set the standard parameters for all response messages
    if response
      response[:channel] = channel_name
      response[:clientId] = clientId
      response[:id] = id
      [response]
    else
      []
    end
  end

  # Send an asynchronous JSON or JSONP response to an async_sinatra GET or POST
  def respond messages
    if jsonp = params['jsonp']
      trace "responding jsonp=#{messages.to_json}"
      headers({'Content-Type' => 'text/javascript'})
      body "#{jsonp}(#{messages.to_json});\n"
    else
      trace "responding #{messages.to_json}"
      headers({'Content-Type' => 'application/json'})
      body messages.to_json
    end
  end

  protected

  # Handle a handshake request from a client
  def handshake message
    publish :channel => '/cometd/meta', :data => {}, :action => "handshake", :reestablish => false, :successful => true
    publish :channel => '/cometd/meta', :data => {}, :action => "connect", :successful => true
    interval = params['jsonp'] ? settings.poll_interval : settings.long_poll_interval
    trace "Setting interval to #{interval}"
    {
      :version => '1.0',
      :supportedConnectionTypes => ['long-polling','callback-polling'],
      :successful => true,
      :advice => { :reconnect => 'retry', :interval => interval*1000 },
      :minimumVersion => message['minimumVersion'],
    }
  end

  # Handle a request by a client to subscribe to a channel
  def subscribe message
    clientId = message['clientId']
    subscription = message['subscription']
    if subscription =~ %r{^/meta/}
      # No-one may subscribe to meta channels.
      # The Bayeux protocol allows server-side clients to (e.g. monitoring apps) but we don't.
      trace "Client #{clientId} may not subscribe to #{subscription}"
      { :successful => false, :error => "500" }
    else
      subscribed_channel = subscription
      trace "Client #{clientId} wants messages from #{subscribed_channel}"
      client_array = channels[subscribed_channel]
      client = clients[clientId]
      if client and !client_array.include?(client)
        client_array << client
        client.channels << subscribed_channel
      end
      publish message
      {
        :successful => true,
        :subscription => subscribed_channel
      }
    end
  end

  # Handle a request by a client to unsubscribe from a channel
  def unsubscribe message
    clientId = message['clientId']
    subscribed_channel = message['subscription']
    trace "Client #{clientId} no longer wants messages from #{subscribed_channel}"
    client_array = channels[subscribed_channel]
    client = clients[clientId]
    client.channels.delete(subscribed_channel)
    client_array.delete(client)
    publish message
    {
      :successful => true,
      :subscription => subscribed_channel
    }
  end

  # Handle a long-poll request by a client
  def connect message
    @is_connect = true
    clientId = message['clientId']
    # trace "Client #{clientId} is long-polling"
    client = clients[clientId]
    pass unless client        # Or "not authorised", or "handshake"?

    connect_response = {
      :channel => '/meta/connect', :clientId => clientId, :id => message['id'], :successful => true
    }

    queued = client.queue
    if !queued.empty? || client.subscription
      if client.subscription
        # If the client opened a second long-poll, finish that one and this:
        trace "Another long-poll seems to be already active for #{clientId}; close it!"
        client.channel.push true    # Complete the outstanding poll
      end
      client.queue << connect_response
      client.flush(self)
      return
    end

    client.subscription =
      client.channel.subscribe do |msg|
        queued = client.queue
        if queued.empty?
          trace "Client #{clientId} awoke but found an empty queue"
        end
        client.queue << connect_response
        client.flush(self)
      end

    if client.subscription
      # trace "Client #{clientId} is waiting on #{client.subscription}"
      on_close {
        client.channel.unsubscribe(client.subscription)
        client.subscription = nil
      }
    else
      trace "Client #{clientId} failed to wait"
    end
    nil
  end

  # Handle a disconnect request from a client
  def disconnect message
    clientId = message['clientId']
    if client = clients[clientId]
      # Unsubscribe all subscribed channels:
      while !client.channels.empty?
        unsubscribe({'clientId' => clientId, 'channel' => '/meta/unsubscribe', 'subscription' => client.channels[0]})
      end
      client.queue += [{:channel => '/cometd/meta', :data => {}, :action => "connect", :successful => false}]
      # Finish an outstanding poll:
      client.channel.push true if client.subscription
      clients.delete(clientId)
      { :successful => true }
    else
      { :successful => false }
    end
  end

  # Deliver a Bayeux message or array of messages
  def deliver_all(message)
    begin
      if message.is_a?(Array)
        response = []
        message.map do |m|
          response += [deliver(m)].flatten
        end
        response
      else
        Array(deliver(message))
      end
    rescue NameError    # Usually an "Uncaught throw" from calling pass
      raise
    rescue => e
      puts "#{e.class.name}: #{e.to_s}\n#{e.backtrace*"\n\t"}"
    end
  end

  # Parse a message (or array of messages) from an HTTP request and deliver the messages
  def receive message_json
    message = [JSON.parse(message_json)].flatten

    clientId = message[0]['clientId']
    channel_name = message[0]['channel']
    if (channel_name == '/meta/handshake' && message.size == 1)
      respond(deliver(message[0]))
    else
      client = clients[clientId]
      if (!client)
        respond([{:advice => {:reconnect => :handshake}}])
      else
        # The message here should either be a connect message (long-poll) or messages being sent.
        # For a long-poll we return a reponse immediately only if messages are queued for this client.
        # For a send-message, we always return a response immediately, even if it's just an acknowledgement.
        @is_connect = false
        response = deliver_all(message)
        if @is_connect   # A long poll
          return
        end
        client.queue += response
        client.flush if params['jsonp'] || !client.queue.empty?
      end
    end

  rescue => e
    respond([])
  end

  # Normal JSON operation uses a POST
  apost '/cometd' do
    receive params['message']
  end

  # JSONP always uses a GET, since it fulfils a script tag.
  # GETs can only send data which fit into a single URL.
  aget '/cometd' do
    receive params['message']
  end

end
