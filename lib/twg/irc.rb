require 'twg/game'
module TWG
  class IRC
    include Cinch::Plugin
    listen_to :enter_night, :method => :enter_night
    listen_to :enter_day, :method => :enter_day
    listen_to :exit_night, :method => :exit_night
    listen_to :exit_day, :method => :exit_day
    listen_to :ten_seconds_left, :method => :ten_seconds_left
    listen_to :warn_vote_timeout, :method => :warn_vote_timeout
    listen_to :complete_startup, :method => :complete_startup
    listen_to :hook_notify_roles, :method => :notify_roles
    listen_to :nick, :method => :nickchange
    listen_to :op, :method => :opped
    listen_to :deop, :method => :opped
    listen_to :do_allow_starts, :method => :do_allow_starts
    match "start", :method => :start
    match /vote ([^ ]+)(.*)?$/, :method => :vote
    match "votes", :method => :votes
    match "join", :method => :join
    match /join ([^ ]+)$/, :method => :forcejoin

    attr_accessor :timer

    def initialize(*args)
      super
      shared[:game] = TWG::Game.new if shared[:game].nil?
      @timer = nil
      @allow_starts = false
      @authnames = {}
    end

    def authn(user)
      return true if not config["use_authname"]
      @authnames[user.to_s] == user.authname
    end

    def cancel_dispatch(run = false)
      return if @timer.nil?
      return if @timer.stopped?
      @timer.stop
      return if not run
      @timer.interval = 0
      @timer.shots = 1
      @timer.start
    end

    def vote(m, mfor, reason)
      unless shared[:game].nil?
        return if not authn(m.user)
        r = shared[:game].vote(m.user.to_s, mfor, (m.channel? ? :channel : :private))
        if r.code == :confirmvote
          if m.channel?
            rmessage = "#{m.user} voted for %s" % Format(:bold, mfor)
          else
            rmessage = "You have voted for #{mfor} to be killed tonight"
          end
        elsif r.code == :changedvote
          if m.channel?
            rmessage = "#{m.user} %s their vote to %s" % [Format(:bold, "changed"), Format(:bold, mfor)]
          else
            rmessage = "You have changed your vote to #{mfor}"
          end
        elsif r.code == :fellowwolf
          rmessage = "You can't vote for one of your own kind!"
        elsif r.code == :voteenotplayer
          if m.channel?
            rmessage = "#{m.user}: #{mfor} is not a player in this game"
          else
            rmessage = "#{mfor} is not a player in this game"
          end
        elsif r.code == :voteedead
          if m.channel?
            rmessage = "Good news #{m.user}, #{mfor} is already dead! "
          else
            rmessage = "#{mfor} is already dead"
          end
        elsif r.code == :voteself
          if not m.channel?
            rmessage = "Error ID - 10T"
          end
        end
        if rmessage
          m.reply rmessage
        end
      end
    end
    
    def votes(m)
      return if !m.channel?
      return if shared[:game].state != :day
      tally = {}
      shared[:game].voted.each do |voter,votee|
        if tally[votee]
          tally[votee] << voter
        else
          tally[votee] = [voter]
        end
      end
      tally.each do |votee,voters|
        chanm "#{votee} has #{voters.count} vote#{voters.count > 1 ? "s" : nil} (#{voters.join(', ')})."
      end
    end
    
    def opped(m, *args)
      @isopped ||= false
      debug "Opped params: %s" % m.params.inspect 
      chan, mode, user = m.params
      shared[:game] = TWG::Game.new if shared[:game].nil?
      if chan == config["game_channel"] && mode == "+o" && user == bot.nick
        @isopped = true
        unless [:night,:day].include?(shared[:game].state) || @signup_started == true
          wipe_slate
          delaydispatch(15, :do_allow_starts)
        end
      elsif chan == config["game_channel"] && mode == "-o" && user == bot.nick
        chanm Format(:bold, "Cancelling game! I have been deopped!") if shared[:game].state != :signup || (shared[:game].state == :signup && @signup_started == true)
        shared[:game] = nil
        @signup_started = false
        @isopped = false
        @allow_starts = false
      end
    end

    def do_allow_starts(m)
      chanm "TWG bot is now up and running! Say !start to start a new game."
      @allow_starts = true
    end

    def nickchange(m)
      oldname = m.user.last_nick.to_s
      newname = m.user.to_s
      return if shared[:game].nil?
      return if shared[:game].participants[oldname].nil?
      return if shared[:game].participants[oldname] == :dead
      if not @authnames.delete(oldname).nil?
        shared[:game].nickchange(oldname, newname)
        @authnames[newname] = m.user.authname
        chanm("Player %s is now known as %s" % [Format(:bold, m.user.last_nick), Format(:bold, m.user.to_s)])
      end
    end

    def start(m)
      return if !m.channel?
      return if m.channel != config["game_channel"]
      if !@allow_starts
        if @isopped
          m.reply "I'm not ready yet, #{m.user.to_s}. Give me a few seconds."
        else
          m.reply "I require channel ops before starting a game"
        end 
        return
      end
      if shared[:game].nil?
        shared[:game] = TWG::Game.new
      else
        if @signup_started == true
          cancel_dispatch(true)
          return
        end
      end
      if shared[:game].state.nil? || shared[:game].state == :wolveswin || shared[:game].state == :humanswin
        shared[:game].reset
      end
      if shared[:game].state == :signup
        unless m.user.authname.nil?
          wipe_slate
          @signup_started = true
          m.reply "TWG has been started by #{m.user}!"
          m.reply "Registration is now open, say !join to join the game within #{config["game_timers"]["registration"]} seconds, !help for more information. A minimum of #{shared[:game].min_part} players is required to play TWG."
          m.reply "Say !start again to skip the wait when everybody has joined"
          shared[:game].register(m.user.to_s)
          voice(m.user)
          @authnames[m.user.to_s] = m.user.authname
          delaydispatch(config["game_timers"]["registration"] - 10, :ten_seconds_left, m)
        else
          m.reply "you are unable to start a game as you are not authenticated to network services", true
        end
      end
    end

    def complete_startup(m)
      return if shared[:game].nil?
      return unless shared[:game].state == :signup
      r = shared[:game].start
      @signup_started = false

      if r.code == :gamestart
        chanm "%s Players are: %s" % [Format(:bold, "Game starting!"), shared[:game].participants.keys.sort.join(', ')]
        chanm "You will shortly receive your role via private message"
        Channel(config["game_channel"]).mode('+m')
        hook_sync(:hook_roles_assigned)
        hook_async(:hook_notify_roles)
        delaydispatch(10, :enter_night)
      elsif r.code == :notenoughplayers
        chanm "Not enough players to start a game, sorry guys. You can !start another if you find more players."
        wipe_slate
      else
        chanm Format(:red, "An unexpected error occured, the game could not be started.")
        wipe_slate
      end
    end
    
    def join(m)
      return if !m.channel?
      return if !@signup_started
      if m.user.authname.nil?
        m.reply "unable to add you to the game, you are not identified with services", true
        return
      end
      if !shared[:game].nil? && shared[:game].state == :signup
        r = shared[:game].register(m.user.to_s)
        if r.code == :confirmplayer
          m.reply "#{m.user} has joined the game (#{shared[:game].participants.length}/#{shared[:game].min_part}[minimum])"
          Channel(config["game_channel"]).voice(m.user)
          @authnames[m.user.to_s] = m.user.authname
        end
      end
    end

    def forcejoin(m, user)
      return if not m.channel?
      return if not admin?(m.user)
      return if not @signup_started
      return if shared[:game].nil?
      return if shared[:game].state != :signup
      uobj = User(user)
      uobj.refresh
      if uobj.authname.nil?
        m.reply "Unable to add #{user} to the game - not identified with services", true
        return
      end
      r = shared[:game].register(user)
      if r.code == :confirmplayer
        m.reply "#{user} has been forced to join the game (#{shared[:game].participants.length}/#{shared[:game].min_part}[minimum])"
        Channel(config["game_channel"]).voice(uobj)
        @authnames[user] = uobj.authname
      end
    end

    def ten_seconds_left(m)
      return if shared[:game].nil?
      return unless shared[:game].state == :signup
      chanm "10 seconds left to !join. #{shared[:game].participants.length} out of a minimum of #{shared[:game].min_part} players joined so far."
      delaydispatch(10, :complete_startup, m)
    end

    def warn_vote_timeout(m, secsremain)
      return if shared[:game].nil?
      if shared[:game].state == :day
        notvoted = []
        shared[:game].participants.each do |player,state|
          next if state == :dead
          unless shared[:game].voted.keys.include?(player)
            notvoted << player
          end
        end
        wmessage = Format(:bold, "Voting closes in #{secsremain} seconds! ")
        if notvoted.count > 0
          wmessage << "Yet to vote: #{notvoted.join(', ')}"
        else
          wmessage << "Everybody has voted, but it's not too late to change your mind..." 
        end
        chanm(wmessage)
      end
    end

    def enter_night(m)
      return if shared[:game].nil?
      chanm("A chilly mist descends, %s #{shared[:game].iteration}. Villagers, sleep soundly. Wolves, you have #{config["game_timers"]["night"]} seconds to decide who to rip to shreds." % Format(:underline, "it is now NIGHT"))
      shared[:game].state_transition_in
      solicit_wolf_votes 
      delaydispatch(config["game_timers"]["night"], :exit_night, m)
    end
  
    def exit_night(m)
      return if shared[:game].nil?
      r = shared[:game].apply_votes
      shared[:game].next_state
      bot.handlers.dispatch(:seer_reveal, m, shared[:game].reveal)
      if r.code == :normkilled
        k = r.opts[:killed]
        chanm("A bloodcurdling scream is heard throughout the village. Everybody rushes to find the broken body of #{k} lying on the ground. %s" % Format(:red, "#{k.capitalize}, a villager, is dead."))
        devoice(k)
      elsif r.code == :novotes
        k = :none
        chanm("Everybody wakes, bleary eyed. %s Nobody was murdered during the night!" % Format(:underline, "There doesn't appear to be a body!"))
      end
      unless check_victory_conditions
        bot.handlers.dispatch(:enter_day, m, k)
      end
    end

    def enter_day(m,killed)
      return if shared[:game].nil?
      shared[:game].state_transition_in
      solicit_human_votes(killed)
      warn_timeout = config["game_timers"]["day_warn"]
      warn_timeout = [warn_timeout] if warn_timeout.class != Array
      warn_timeout.each do |warnat|
        secsremain = config["game_timers"]["day"].to_i - warnat.to_i
        delaydispatch(secsremain, :warn_vote_timeout, m, warnat.to_i)
      end
      delaydispatch(config["game_timers"]["day"], :exit_day, m)
    end

    def exit_day(m)
      return if shared[:game].nil?
      r = shared[:game].apply_votes
      shared[:game].next_state
      k = r.opts[:killed]
      unless r.code == :novotes
        chanm "Voting over! The baying mob has spoken - %s must die!" % Format(:bold, k)
        sleep 2
        chanm("Everybody turns slowly towards #{k}, who backs into a corner. With a quick flurry of pitchforks #{k} is no more. The villagers examine the body...")
        sleep(config["game_timers"]["dramatic_effect"])
      else
        chanm("Voting over! No consensus could be reached.")
      end
      if r.code == :normkilled
        chanm("...but can't see anything unusual, looks like you might have turned upon one of your own.")
        devoice(k)
      elsif r.code == :wolfkilled
        chanm("...and it starts to transform before their very eyes! A dead wolf lies before them.")
        devoice(k)
      end
      unless check_victory_conditions
        bot.handlers.dispatch(:enter_night,m)
      end
    end

    def notify_roles(m)
      return if shared[:game].nil?
      shared[:game].participants.keys.each do |user|
        case shared[:game].participants[user]
        when :normal
          userm(user, "You are a normal human being.")
        when :wolf
          if user == "michal"
            userm(user, "Holy shit you're finally a WOLF!")
          else
            userm(user, "You are a WOLF!")
          end
          wolfcp = shared[:game].game_wolves.dup
          wolfcp.delete(user)
          if wolfcp.length > 1
            userm(user, "Your fellow wolves are: #{wolfcp.join(', ')}")
          elsif wolfcp.length == 1
            userm(user, "Your fellow wolf is: #{wolfcp[0]}")
          elsif wolfcp.length == 0
            userm(user, "You are the only wolf in this game.")
          end
        end
      end
    end

    def admin?(user)
      user.refresh
      shared[:admins].include?(user.authname)
    end

    # TODO: replace delaydispatch with a hook_ method
    def delaydispatch(secs, method, m = nil, *args)
      @timer = Timer(secs, {:shots => 1}) do
        bot.handlers.dispatch(method, m, *args)
      end
    end

    def hook_raise(method, async=true, m=nil, *args)
      debug "Calling #{async ? 'async' : 'sync'} hook: #{method.to_s}"
      ta = bot.handlers.dispatch(method, m, *args)
      debug "Hooked threads for #{method.to_s}: #{ta}"
      return ta if async
      return ta if not ta.respond_to?(:each)
      debug "Joining threads for #{method.to_s}"
      ta.each do |thread|
        begin 
          thread.join
        rescue => e
          debug e.inspect
        end
      end
      debug "Hooked threads for #{method.to_s} complete"
      ta
    end

    def hook_async(method, m=nil, *args)
      hook_raise(method, true, m, *args)
    end

    def hook_sync(method, m=nil, *args)
      hook_raise(method, false, m, *args)
    end

    def check_victory_conditions
      return if shared[:game].nil?
      if shared[:game].state == :wolveswin
        if shared[:game].live_wolves > 1
          chanm "With a bloodcurdling howl, hair begins sprouting from every orifice of the #{shared[:game].live_wolves} triumphant wolves. The remaining villagers don't stand a chance." 
        else
          chanm("With a bloodcurdling howl, hair begins sprouting from %s's every orifice. The remaining villagers don't stand a chance." % Format(:bold, shared[:game].wolves_alive[0]))
        end
        if shared[:game].game_wolves.length == 1
          chanm("Game over! The lone wolf %s wins!" % Format(:bold, shared[:game].wolves_alive[0]))
        else
          if shared[:game].live_wolves == shared[:game].game_wolves.length
            chanm("Game over! The wolves (%s) win!" % Format(:bold, shared[:game].game_wolves.join(', ')))
          elsif shared[:game].live_wolves > 1
            chanm("Game over! The remaining wolves (%s) win!" % Format(:bold, shared[:game].wolves_alive.join(', ')))
          else
            chanm("Game over! The last remaining wolf, %s, wins!" % Format(:bold, shared[:game].wolves_alive[0]))
          end
        end
        wipe_slate
        return true
      elsif shared[:game].state == :humanswin
        if shared[:game].game_wolves.length > 1
          chanm("Game over! The wolves (%s) were unable to pull the wool over the humans' eyes." % Format(:bold, shared[:game].game_wolves.join(', ')))
        else
          chanm("Game over! The lone wolf %s was unable to pull the wool over the humans' eyes." % Format(:bold, shared[:game].game_wolves[0]))
        end
        wipe_slate
        return true
      else
        return false
      end
    end

    def devoice(uname)
      Channel(config["game_channel"]).devoice(uname)
    end

    def voice(uname)
      Channel(config["game_channel"]).voice(uname)
    end
    
    def solicit_votes
      return if shared[:game].nil?
      if shared[:game].state == :night
        solicit_wolf_votes
      elsif shared[:game].state == :day
        solicit_human_votes
      end
    end

    def solicit_wolf_votes
      return if shared[:game].nil?
      alive = shared[:game].wolves_alive
      if alive.length == 1
        if shared[:game].game_wolves.length == 1
          whatwereyou = "You are a lone wolf."
        else
          whatwereyou = "You are the last remaining wolf."
        end
        userm(alive[0], "It is now NIGHT #{shared[:game].iteration}: #{whatwereyou} To choose the object of your bloodlust, say !vote <nickname> to me. You can !vote again if you change your mind.")
        return
      elsif alive.length == 2
        others = "Talk with your fellow wolf"
      else
        others = "Talk with your fellow wolves to decide who to kill"
      end
      alive.each do |wolf|
        userm(wolf, "It is now NIGHT #{shared[:game].iteration}: To choose the object of your bloodlust, say !vote <nickname> to me. You can !vote again if you change your mind. #{others}") 
      end
    end

    def solicit_human_votes(killed=:none)
      return if shared[:game].nil?
      if killed == :none
        blurb = "Talk to your fellow villagers about this unusual and eery lupine silence!"
      else
        blurb = "Talk to your fellow villagers about #{killed}'s untimely demise!"
      end
      chanm("It is now DAY #{shared[:game].iteration}: #{blurb} You have #{config["game_timers"]["day"]} seconds to vote on who to lynch by saying !vote nickname. If you change your mind, !vote again.")
    end

    def chanm(m)
      Channel(config["game_channel"]).send(m)
    end

    def userm(user, m)
      User(user).send(m)
    end

    def wipe_slate
      shared[:game].reset
      @signup_started = false
      @timer = nil
      @gchan = Channel(config["game_channel"])
      @authnames = {}
      @gchan.mode('-m')
      deop = []
      devoice = []
      @gchan.users.each do |user,mode|
        next if user == bot.nick
        deop << user if mode.include? 'o'
        devoice << user if mode.include? 'v'
      end
      multimode(deop, config["game_channel"], "-", "o")
      multimode(devoice, config["game_channel"], "-", "v")
    end

    def multimode(musers, mchannel, direction, mode)
      while musers.count > 0
        if musers.count < 4
          rc = musers.count
        else
          rc = 4
        end
        add = musers.pop(rc)
        ms = direction + mode * rc
        bot.irc.send "MODE %s %s %s" % [mchannel, ms, add.join(" ")]
      end
    end

  end

end