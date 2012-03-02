# IRC client implementation for YIBot 2.0. Technically, it's main part of
# program, but YIBot now supports not only IRC :).
{Server} = require '../server'

# Initalize remove function for arrays
remove = (value) ->
  index = this.indexOf(value)
  if index isnt -1
    this.splice(index, 1)

# Class IRC itself
class exports.IRC extends Server

  constructor: (@name, @config) ->
    if @config.Host?
      # Usual IRC port
      @config.Port ?= 6667

      # Constructors are SUPER. Well, actually it activates original
      # constructor which makes various initialization.
      super
    else
      throw new Error "Server #{@name} doesn't have specified server!"

  # Sends raw command to the server. Don't use it unless you can confirm
  # using @config.Type that you're talking with "IRC".
  raw: (msg) =>
    @log msg, 'write'
    @client.write "#{msg}\r\n"

  connect: =>
    net = require('net')

    @client = net.connect(@config.Port, @config.Host)

    # This code is likely to fail. If this happens, catch exception and stop
    # trying to parse the message (but avoid useless crashes which may
    # happen sadly).
    @client.on 'data', (data) =>
      try
        @onData data
      catch exception
        throw exception if @config.Debug
        @log exception.message, 'error'

    @client.on 'end', (data) =>
      # Make reconnection
      new exports.IRC(@name, @config).connect()

    @client.setEncoding('utf8')
    @raw "NICK #{@config.Nick}"
    @raw "USER #{@config.User} place holder :#{@config.Realname}"

    @nick = @config.Nick

  join: (channel) =>
    # Channels are case insensitive. This is attempt to fix this.
    channel = channel.toLowerCase()

    if @channels[channel]?
      throw new Error 'Bot has tried to join channel which already exists.'
    @channels[channel] = [@nick]
    @raw "JOIN #{channel}"
    true

  part: (channel) =>
    # Channels are case insensitive. This is attempt to fix this.
    channel = channel.toLowerCase()

    if @channels[channel]?
      @raw "PART #{channel}"
      delete @channels[channel]
      true
    else
      throw new Error "#{channel} already is left."

  nick: (nick) ->
    [@oldnick, @nick] = [@nick, nick]
    @raw "NICK #{nick}"
    true

  onData: (data) =>
    # Sometimes servers split messages using \r. Node expects \n instead.
    # This call should fix it.
    data = data.replace(/^\s+|\s+$/g, '').split("\r")

    if (data.length > 1)
      for line in data
        @onData line
      return

    data = data[0]

    # If data is empty, it's probably a bug. Ignore it.
    return if data is ''

    @log data

    # Some servers seem to insert ":" at beginning for some reason. This
    # function will fix those cases.
    data = data.replace(/^:/, '')

    data = data.split(' ')

    for value, i in data
      break if /^:/.test(value)

    # Complex call which sets data to the array of values before ":" has
    # showed in query and joined with spaces string after ":" character.
    data = [data[0...i]..., data[i..].join(' ').replace(/^:/, '')]

    if (data[0] is 'PING')
      @raw "PONG :#{data[1]}"
    else
      @message = {}
      user = /(.*)!((.*)@(.*))/.exec(data[0])
      if user?
        # Set variables for regular expressions parts
        [
          @message.fullhost
          @message.nick
          @message.host
          @message.user
          @message.address
        ] = user

        # Check if user is owner
        @message.owner = @config.Owner.test(@message.host)

    @message.type = data[1].toLowerCase()

    switch @message.type
      # When '001' is received you're free to join any channel
      when '001'
        for channel in @config.Channels
          @join channel
      # Nickname in use or unknown nick
      when '432', '433'
        @nick = @oldnick
      # List of users in this channel
      when '353'
        channel = data[4].toLowerCase()

        nicks = data[5].split(' ')

        for nick in nicks
          nick = nick.replace(/^[^A-}]+/, '')
          # Ignore my bot name
          continue if nick is @nick
          # Remove modes at beginning. Those characters aren't allowed in
          # IRC nicknames anyway, so there is no danger in removing those.
          @channels[channel].push(nick)

      when 'part'
        @message.channel = data[2].toLowerCase()
        remove @channels[@message.channel], @message.nick
      when 'join'
        break if @message.nick is @nick
        @message.channel = data[2].toLowerCase()
        @channels[@message.channel].push(@message.nick)
      when 'quit'
        for channel of @channels
          remove @channels[channel], @message.nick
      when 'privmsg'
        @message.channel = data[2].toLowerCase()
        @message.text = data[3]

        if @message.channel[0] is '#'
          @message.type = 'message'
        else
          @message.type = 'private'

        @parseMessage()
      when 'invite'
        @message.channel = data[3].toLowerCase()
        if @config.ReactOnInvite
          @join @message.channel
        if typeof @config.ReactOnInvite is 'string'
          message = @config.ReactOnInvite.replace('%s', @message.nick)
          @send message, @message.channel

    @loadPlugins()

    # In case of setTimeout attack (not really)
    @message = {}

  respond: (msg, me = false) =>
    if @message.channel?
      @send msg, @message.channel, me
    else
      throw new Error 'You cannot respond to this message.'

  # This is rather tricky version of send, needed because of IRC specifics.
  send: (message, channel, me = false) =>
    if message instanceof Array
      for msg in message
        @send msg, channel
    else
      # Make nice message split.
      message = "#{message}".split(/\r?\n|\r/)

      for msg, i in message
        line = msg.match(/.{1,400}(\s|$)|.{400}|.+$/g)
        for text in line
          continue if text is ''
          if me
            text = "\x01ACTION #{text}\x01"
          else
            text = "\x02\x02#{text}"
          @raw "PRIVMSG #{channel} :#{text}"
    # This true will return "true" which in plugin will stop execution.
    true

  # In case of IRC, it's alias, but it's not always the case.
  pm: (message, channel, me = false) => @send message, channel, me