

module Rye
  
  
  # = Rye::Box
  #
  # The Rye::Box class represents a machine. All system
  # commands are made through this class.
  #
  #     rbox = Rye::Box.new('filibuster')
  #     rbox.hostname   # => filibuster
  #     rbox.uname      # => FreeBSD
  #     rbox.uptime     # => 20:53  up 1 day,  1:52, 4 users
  #
  # You can also run local commands through SSH
  #
  #     rbox = Rye::Box.new('localhost') 
  #     rbox.hostname   # => localhost
  #     rbox.uname(:a)  # => Darwin vanya 9.6.0 ...
  #
  #--
  # * When anything confusing happens, enable debug in initialize
  # by passing :debug => STDERR. This will output Rye debug info
  # as well as Net::SSH info. This is VERY helpful for figuring
  # out why some command is hanging or otherwise acting weird. 
  # * If a remote command is hanging, it's probably because a
  # Net::SSH channel is waiting on_extended_data (a prompt). 
  #++
  class Box 
    include Rye::Cmd
    
      # An instance of Net::SSH::Connection::Session
    attr_reader :ssh
    
    attr_reader :info
    attr_reader :debug
    attr_reader :error
    
    attr_accessor :host
    
    attr_accessor :safe
    attr_accessor :opts

      # The most recent value from Box.cd or Box.[]
    attr_reader :current_working_directory
      # The most recent valud for umask (or 0022)
    attr_reader :current_umask
    
    # * +host+ The hostname to connect to. The default is localhost.
    # * +opts+ a hash of optional arguments.
    #
    # The +opts+ hash excepts the following keys:
    #
    # * :user => the username to connect as. Default: the current user. 
    # * :safe => should Rye be safe? Default: true
    # * :keys => one or more private key file paths (passwordless login)
    # * :password => the user's password (ignored if there's a valid private key)
    # * :info => an IO object to print Rye::Box command info to. Default: nil
    # * :debug => an IO object to print Rye::Box debugging info to. Default: nil
    # * :error => an IO object to print Rye::Box errors to. Default: STDERR
    #
    # NOTE: +opts+ can also contain any parameter supported by 
    # Net::SSH.start that is not already mentioned above.
    #
    def initialize(host='localhost', opts={})
      
      # These opts are use by Rye::Box and also passed to Net::SSH
      @opts = {
        :user => Rye.sysinfo.user, 
        :safe => true,
        :port => 22,
        :keys => [],
        :info => nil,
        :debug => nil,
        :error => STDERR,
      }.merge(opts)
      
      # See Net::SSH.start
      @opts[:paranoid] = true unless @opts[:safe] == false
      
      # Close the SSH session before Ruby exits. This will do nothing
      # if disconnect has already been called explicitly. 
      at_exit {
        self.disconnect
      }
            
      @host = host
      
      @safe = @opts.delete(:safe)
      @debug = @opts.delete(:debug)
      @error = @opts.delete(:error)
      @info = @opts.delete(:info)
      
      @debug = STDERR if @debug == true
      @error = STDERR if @error == true
      @info = STDOUT if @info == true
      
      if @debug
        @opts[:logger] = Logger.new(@debug)
      end
      
      debug @opts.inspect
            
      add_keys(@opts[:keys])
      
      # We don't want Net::SSH to handle the keypairs. This may change
      # but for we're letting ssh-agent do it. 
      #@opts.delete(:keys)
      
      # From: capistrano/lib/capistrano/cli.rb
      STDOUT.sync = true # so that Net::SSH prompts show up
      
      debug "ssh-agent info: #{Rye.sshagent_info.inspect}"
      
    end
    
     
    # Returns an Array of system commands available over SSH
    def can
      Rye::Cmd.instance_methods
    end
    alias :commands :can
    alias :cmds :can
    

      
    # Change the current working directory (sort of). 
    #
    # I haven't been able to wrangle Net::SSH to do my bidding. 
    # "My bidding" in this case, is maintaining an open channel between commands.
    # I'm using Net::SSH::Connection::Session#exec for all commands
    # which is like a funky helper method that opens a new channel
    # each time it's called. This seems to be okay for one-off 
    # commands but changing the directory only works for the channel
    # it's executed in. The next time exec is called, there's a
    # new channel which is back in the default (home) directory. 
    #
    # Long story short, the work around is to maintain the current
    # directory locally and send it with each command. 
    # 
    #     rbox.pwd              # => /home/rye ($ pwd )
    #     rbox['/usr/bin'].pwd  # => /usr/bin  ($ cd /usr/bin && pwd)
    #     rbox.pwd              # => /usr/bin  ($ cd /usr/bin && pwd)
    #
    def [](key=nil)
      @current_working_directory = key
      self
    end
    # Like [] except it returns an empty Rye::Rap object to mimick
    # a regular command method. Call with nil key (or no arg) to 
    # reset. 
    def cd(key=nil)
      @current_working_directory = key
      ret = Rye::Rap.new(self)
    end
    
    # Change the current umask (sort of -- works the same way as cd)
    # The default umask is 0022
    def umask=(val='0022')
      @current_umask = val
      self
    end
    
    # Execute subsequent commands via +su -c COMMAND user+
    # * +user+ is the the remote user name to run as. Set to nil to remove. 
    def su=(user)
      @current_su = user
      self
    end
      
    # Open an SSH session with +@host+. This called automatically
    # when you the first comamnd is run if it's not already connected.
    # Raises a Rye::NoHost exception if +@host+ is not specified.
    # Will attempt a password login up to 3 times if the initial 
    # authentication fails. 
    # * +reconnect+ Disconnect first if already connected. The default
    # is true. When set to false, connect will do nothing if already 
    # connected. 
    def connect(reconnect=true)
      raise Rye::NoHost unless @host
      return if @ssh && !reconnect
      disconnect if @ssh 
      debug "Opening connection to #{@host} as #{@opts[:user]}"
      highline = HighLine.new # Used for password prompt
      retried = 0
      
      begin
        @ssh = Net::SSH.start(@host, @opts[:user], @opts || {}) 

      rescue Net::SSH::HostKeyMismatch => ex
        STDERR.puts ex.message
        STDERR.puts "NOTE: EC2 instances generate new SSH keys on first boot."
        print "\a" # Ring the bell
        if highline.ask("Continue? ").strip.match(/\Ay|yes|sure|ya\z/i)
          @opts[:paranoid] = false
          retry
        else
          raise Net::SSH::HostKeyMismatch
        end
      rescue Net::SSH::AuthenticationFailed => ex
        retried += 1
        if STDIN.tty? && retried <= 3
          @opts[:password] = highline.ask("Password: ") { |q| q.echo = '' }
          @opts[:auth_methods] ||= []
          @opts[:auth_methods] << 'password'
          retry
        else
          raise Net::SSH::AuthenticationFailed
        end
      end
      
      # We add :auth_methods (a Net::SSH joint) to force asking for a
      # password if the initial (key-based) authentication fails. We
      # need to delete the key from @opts otherwise it lingers until
      # the next connection (if we switch_user is called for example).
      @opts.delete :auth_methods if @opts.has_key?(:auth_methods)
      
      @ssh.is_a?(Net::SSH::Connection::Session) && !@ssh.closed?
      self
    end
    
    # Reconnect as another user. This is different from su=
    # which executes subsequent commands via +su -c COMMAND USER+. 
    # * +newuser+ The username to reconnect as 
    #
    # NOTE: if there is an open connection, it's disconnected
    # and a new one is opened for the given user. 
    def switch_user(newuser)
      return if newuser.to_s == self.user.to_s
      @opts ||= {}
      @opts[:user] = newuser
      disconnect
      connect
    end
    
    
    # Close the SSH session  with +@host+. This is called 
    # automatically at exit if the connection is open. 
    def disconnect
      return unless @ssh && !@ssh.closed?
      @ssh.loop(0.1) { @ssh.busy? }
      debug "Closing connection to #{@ssh.host}"
      @ssh.close
    end
    
    
    # Open an interactive SSH session. This only works if STDIN.tty?
    # returns true. Otherwise it returns the SSH command that would 
    # have been run. This requires the SSH command-line executable (ssh).
    # * +run+ when set to false, it will return the SSH command as a String
    # and not open an SSH session.
    #
    def interactive_ssh(run=true)
      debug "interactive_ssh with keys: #{Rye.keys.inspect}"
      run = false unless STDIN.tty?      
      cmd = Rye.prepare_command("ssh", "#{@opts[:user]}@#{@host}")
      return cmd unless run
      system(cmd)
    end
    
    # Add one or more private keys to the SSH Agent. 
    # * +additional_keys+ is a list of file paths to private keys
    # Returns the instance of Box
    def add_keys(*additional_keys)
      additional_keys = [additional_keys].flatten.compact || []
      return if additional_keys.empty?
      ret = Rye.add_keys(additional_keys)
      if ret.is_a?(Rye::Rap)
        debug "ssh-add exit_code: #{ret.exit_code}" 
        debug "ssh-add stdout: #{ret.stdout}"
        debug "ssh-add stderr: #{ret.stderr}"
      end
      self #MUST RETURN itself
    end
    alias :add_key :add_keys
    
    # Add an environment variable. +n+ and +v+ are the name and value.
    # Returns the instance of Rye::Box
    def add_env(n, v)
      debug "Added env: #{n}=#{v}"
      (@current_environment_variables ||= {})[n] = v
      self
    end
    alias :add_environment_variable :add_env
    
    def user
      (@opts || {})[:user]
    end
    
    # See Rye.keys
    def keys
      Rye.keys
    end
    
    # Returns +@host+
    def to_s
      @host
    end
    
    def inspect
      %q{#<%s:%s cwd=%s umask=%s su=%s env=%s safe=%s opts=%s>} % 
      [self.class.to_s, self.host, 
       @current_working_directory, @current_umask,
       @current_su, (@current_environment_variables || '').inspect,
       self.safe, self.opts.inspect]
    end
    
    # Compares itself with the +other+ box. If the hostnames
    # are the same, this will return true. Otherwise false. 
    def ==(other)
      @host == other.host
    end
    
    # Returns the host SSH keys for this box
    def host_key
      raise "No host" unless @host
      Rye.remote_host_keys(@host)
    end
    
    # Copy the local public keys (as specified by Rye.keys) to 
    # this box into ~/.ssh/authorized_keys and ~/.ssh/authorized_keys2. 
    # Returns an Array of the private keys files used to generate the public keys.
    #
    # NOTE: authorize_keys_remote disables safe-mode for this box while it runs
    # which will hit you funky style if your using a single instance
    # of Rye::Box in a multithreaded situation. 
    #
    def authorize_keys_remote(other_user=nil)
      added_keys = []
      @safe = false
      home_path = "$HOME/.."
      
      Rye.keys.each do |key|
        path = key[2]
        debug "# Public key for #{path}"
        k = Rye::Key.from_file(path).public_key.to_ssh2
        self.su = other_user  # does nothing if nil
        self.mkdir(:p, :m, '700', '$HOME/.ssh') # Silently create dir if it doesn't exist
        self.echo("'#{k}' >> $HOME/.ssh/authorized_keys")
        self.echo("'#{k}' >> $HOME/.ssh/authorized_keys2")
        self.su = nil         # disable su if set
        self.chmod('-R', '0600', '$HOME/.ssh/authorized_keys*')
        added_keys << path
      end
      @safe = true
      added_keys
    end
    
    # Authorize the current user to login to the local machine via
    # SSH without a password. This is the same functionality as
    # authorize_keys_remote except run with local shell commands. 
    def authorize_keys_local
      added_keys = []
      Rye.keys.each do |key|
        path = key[2]
        debug "# Public key for #{path}"
        k = Rye::Key.from_file(path).public_key.to_ssh2
        Rye.shell(:mkdir, :p, :m, '700', '$HOME/.ssh') # Silently create dir if it doesn't exist
        Rye.shell(:echo, "'#{k}' >> $HOME/.ssh/authorized_keys")
        Rye.shell(:echo, "'#{k}' >> $HOME/.ssh/authorized_keys2")
        Rye.shell(:chmod, '-R', '0600', '$HOME/.ssh/authorized_keys*')
        added_keys << path
      end
      added_keys
    end
    
    # A handler for undefined commands. 
    # Raises Rye::CommandNotFound exception.
    def method_missing(meth, *args, &block)
      raise Rye::CommandNotFound, "#{meth.to_s} (args: #{args.join(' ')})"
    end
    def preview_command(*args)
      prep_args(*args).join(' ')
    end
    
  private
      
    def debug(msg="unknown debug msg"); @debug.puts msg if @debug; end
    def error(msg="unknown error msg"); @error.puts msg if @error; end
    def pinfo(msg="unknown info msg"); @info.print msg if @info; end
    def info(msg="unknown info msg"); @info.puts msg if @info; end
    
    # Add the current environment variables to the beginning of +cmd+
    def prepend_env(cmd)
      return cmd unless @current_environment_variables.is_a?(Hash)
      env = ''
      @current_environment_variables.each_pair do |n,v|
        env << "export #{n}=#{Escape.shell_single_word(v)}; "
      end
      [env, cmd].join(' ')
    end
    


    # Execute a command over SSH
    #
    # * +args+ is a command name and list of arguments. 
    # The command name is the literal name of the command
    # that will be executed in the remote shell. The arguments
    # will be thoroughly escaped and passed to the command.
    #
    #     rbox = Rye::Box.new
    #     rbox.ls '-l', 'arg1', 'arg2'
    #
    # is equivalent to
    #
    #     $ ls -l 'arg1' 'arg2'
    #
    # This method will try to connect to the host automatically
    # but if it fails it will raise a Rye::NotConnected exception. 
    # 
    def run_command(*args)
      debug "run_command with keys: #{Rye.keys.inspect}"
      
      cmd, args = prep_args(*args)
      
      connect if !@ssh || @ssh.closed?
      raise Rye::NotConnected, @host unless @ssh && !@ssh.closed?

      cmd_clean = Rye.escape(@safe, cmd, args)
      cmd_clean = prepend_env(cmd_clean)
      
      # Add the current working directory before the command if supplied. 
      # The command will otherwise run in the user's home directory.
      if @current_working_directory
        cwd = Rye.escape(@safe, 'cd', @current_working_directory)
        cmd_clean = [cwd, cmd_clean].join(' && ')
      end
      
      # ditto (same explanation as cwd)
      if @current_umask
        cwd = Rye.escape(@safe, 'umask', @current_umask)
        cmd_clean = [cwd, cmd_clean].join(' && ')
      end
      
      craxy_file = nil
      if @current_su
        # NASTY NASTY NASTY NASTY NASTY NASTY NASTY NASTY NASTY NASTY NASTY
        # The premise is that quotes get confusing (okay, granted this is a
        # ridiculous solution) so we write a temporary script and call that
        # via su. If I could figure out how to run multiple SSH commands on
        # a the same channel, then we wouldn't need these darn shenanigans.
        craxy_file = Rye.strand(16)
        # echo 'sh command' > craxy_file
        # su -c 'sh craxy_file' @current_su
        update_script = "echo '#{cmd_clean.tr("'", "''")}' > #{craxy_file}"
        info "SU: #{update_script}"
        stdout, stderr, ecode, esignal = net_ssh_exec!(update_script)
        cmd_clean = Rye.escape(@safe, "su", '-c', "'sh #{craxy_file}'", @current_su)
      end
      
      info "COMMAND: #{cmd_clean}"
      debug "Executing: %s" % cmd_clean
      
      stdout, stderr, ecode, esignal = net_ssh_exec!(cmd_clean)
      
      if craxy_file
        net_ssh_exec!("rm #{craxy_file}") rescue nil
      end
      
      rap = Rye::Rap.new(self)
      rap.add_stdout(stdout || '')
      rap.add_stderr(stderr || '')
      rap.add_exit_code(ecode)
      rap.exit_signal = esignal
      rap.cmd = cmd
      
      raise Rye::CommandError.new(rap) if ecode > 0
      
      rap
    end
    alias :cmd :run_command
    
    # Takes a list of arguments appropriate for run_command or
    # preview_command and returns: [cmd, args]
    def prep_args(*args)
      args = args.flatten.compact
      args = args.first.to_s.split(/\s+/) if args.size == 1
      cmd = args.shift
      
      # Symbols to switches. :l -> -l, :help -> --help
      args.collect! do |a|
        if a.is_a?(Symbol)
          a = (a.to_s.size == 1) ? "-#{a}" : "--#{a}"
        end
        a
      end
      [cmd, args]
    end
    
    # Executes +command+ via SSH
    # Returns an Array with 4 elements: [stdout, stderr, exit code, exit signal]
    def net_ssh_exec!(command)
      
      block ||= Proc.new do |channel, type, data|
        channel[:stdout] ||= ""
        channel[:stderr] ||= ""
        channel[:exit_code] ||= -1
        channel[:stdout] << data if type == :stdout
        channel[:stderr] << data if type == :stderr
        channel.on_request("exit-status") do |ch, data|
          # Anything greater than 0 is an error
          channel[:exit_code] = data.read_long
        end
        channel.on_request("exit-signal") do |ch, data|
          # This should be the POSIX SIGNAL that ended the process
          channel[:exit_signal] = data.read_long
        end
        # For long-running commands like top, this will print the output.
        # It's cool, but we'd also need to enable STDIN to interact with 
        # command. 
        #channel.on_data do |ch, data|
        #  puts "got stdout: #{data}"
        #  #channel.send_data "something for stdin\n"
        #end
        #
        #channel.on_extended_data do |ch, data|
        #  #puts "got stdout: #{data}"
        #  #channel.send_data "something for stdin\n"
        #end
      end
      
      channel = @ssh.exec(command, &block)
      channel.wait  # block until we get a response
      
      channel[:exit_code] = 0 if channel[:exit_code] == nil
      channel[:exit_code] &&= channel[:exit_code].to_i
      
      channel[:stderr].gsub!(/bash: line \d+:\s+/, '') if channel[:stderr]
      
      [channel[:stdout], channel[:stderr], channel[:exit_code], channel[:exit_signal]]
    end
    
    
    # * +direction+ is one of :upload, :download
    # * +files+ is an Array of file paths, the content is direction specific.
    # For downloads, +files+ is a list of files to download. The last element
    # must be the local directory to download to. If downloading a single file
    # the last element can be a file path. The target can also be a StringIO.
    # For uploads, +files+ is a list of files to upload. The last element is
    # the directory to upload to. If uploading a single file, the last element
    # can be a file path. The list of files can also include StringIO objects.
    # For both uploads and downloads, the target directory will be created if
    # it does not exist, but only when multiple files are being transferred. 
    # This method will fail early if there are obvious problems with the input
    # parameters. An exception is raised and no files are transferred. 
    def net_scp_transfer!(direction, *files)
      direction ||= ''
      unless [:upload, :download].member?(direction.to_sym)
        raise "Must be one of: upload, download" 
      end
      
      files = [files].flatten.compact || []
      other = files.pop
      
      if direction == :upload && other.is_a?(StringIO)
        raise "Cannot upload to a StringIO object"
      end
      
      # Fail early. We check the 
      files.each do |file|
        if file.is_a?(StringIO)
          raise "Cannot download a StringIO object" if direction == :download
          raise "StringIO object not opened for reading" if file.closed_read?
          # If a StringIO object is at end of file, SCP will hang. (TODO: SCP)
          file.rewind if file.eof?
        end
      end
      
      debug "#{direction.to_s.upcase} TO: #{other}"
      debug "FILES: " << files.join(', ')
      
      # Make sure the remote directory exists. We can do this only when
      # there's more than one file because "other" could be a file name
      if files.size > 1 && !other.is_a?(StringIO)
        debug "CREATING TARGET DIRECTORY: #{other}"
        self.mkdir(:p, other) unless self.file_exists?(other)
      end
      
      Net::SCP.start(@host, @opts[:user], @opts || {}) do |scp|
        transfers = []
        files.each do |file|
          debug file.to_s
          transfers << scp.send(direction, file, other)  do |ch, n, s, t|
            pinfo "#{n}: #{s}/#{t}b\r"  # update line: "file: sent/total"
            @info.flush if @info        # make sure every line is printed
          end
        end
        transfers.each { |t| t.wait }   # Run file transfers in parallel
        info $/
      end
      
      # StringIO objects return nothing when read until they are rewound
      if other.is_a?(StringIO) 
        other.rewind 
        other
      else
        nil
      end
      
    end
    

  end
end

