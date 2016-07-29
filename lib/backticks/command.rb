module Backticks
  # Represents a running process; provides mechanisms for capturing the process's
  # output, passing input, waiting for the process to end, and learning its
  # exitstatus.
  #
  # Interactive commands print their output to Ruby's STDOUT and STDERR
  # in realtime, and also pass input from Ruby's STDIN to the command's stdin.
  class Command
    # Time value that is used internally when a user is willing to wait
    # "forever" for the command.
    #
    # Using a definite time-value helps simplify the looping logic internally,
    # but it does mean that this class will stop working in February of 2106.
    # You have been warned!
    FOREVER = Time.at(2**32-1).freeze

    # Number of bytes to read from the command in one "chunk".
    CHUNK = 1_024

    # @return [Integer] child process ID
    attr_reader :pid

    # @return [nil,Process::Status] result of command if it has ended; nil if still running
    attr_reader :status

    # @return [String] all input that has been captured so far
    attr_reader :captured_input

    # @return [String] all output that has been captured so far
    attr_reader :captured_output

    # @return [String] all output to stderr that has been captured so far
    attr_reader :captured_error

    # Watch a running command.
    def initialize(pid, stdin, stdout, stderr)
      @pid = pid
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr

      @captured_input  = String.new.force_encoding(Encoding::BINARY)
      @captured_output = String.new.force_encoding(Encoding::BINARY)
      @captured_error  = String.new.force_encoding(Encoding::BINARY)
    end

    # @return [String]
    def to_s
      "#<Backticks::Command(@pid=#{pid},@status=#{@status || 'nil'})>"
    end

    def interactive?
      !@stdin.nil?
    end

    # Provide a callback to monitor input and output in real time.
    # @yield
    # @yieldparam
    def tap(&block)
      raise StandardError.new("Tap is already set (#{@tap}); cannot set twice") if @tap && @tap != block
      @tap = block
    end

    # Block until the command exits, or until limit seconds have passed. If
    # interactive is true, pass user input to the command and print its output
    # to Ruby's output streams. If the time limit expires, return `nil`;
    # otherwise, return self.
    #
    # @param [Float,Integer] limit number of seconds to wait before returning
    def join(limit=nil)
      return self if @status

      if limit
        tf = Time.now + limit
      else
        tf = FOREVER
      end

      until (t = Time.now) >= tf
        capture(tf - t)
        res = Process.waitpid(@pid, Process::WNOHANG)
        if res
          @status = $?
          return self
        end
      end

      return nil
    end

    # Block until one of the following happens:
    #  - the command produces fresh output on stdout or stderr
    #  - the user passes some input to the command (if interactive)
    #  - the process exits
    #  - the time limit elapses (if provided) OR 60 seconds pass
    #
    # Return up to CHUNK bytes of fresh output from the process, or return nil
    # if no fresh output was produced
    #
    # @param [Float,Integer] number of seconds to wait before returning nil
    # @return [String,nil] fresh bytes from stdout/stderr, or nil if no output
    def capture(limit=nil)
      streams = [@stdout, @stderr]
      streams << STDIN if interactive?

      if limit
        tf = Time.now + limit
      else
        tf = FOREVER
      end

      ready, _, _ = IO.select(streams, [], [], 0)

      # proxy STDIN to child's stdin
      if ready && ready.include?(STDIN)
        data = STDIN.readpartial(CHUNK) rescue nil
        if data
          data = @tap.call(:stdin, data) if @tap
          if data
            @captured_input << data
            @stdin.write(data)
          end
        else
          @tap.call(:stdin, nil) if @tap
          # our own STDIN got closed; proxy this fact to the child
          @stdin.close unless @stdin.closed?
        end
      end

      # capture child's stdout and maybe proxy to STDOUT
      if ready && ready.include?(@stdout)
        data = @stdout.readpartial(CHUNK) rescue nil
        if data
          data = @tap.call(:stdout, data) if @tap
          if data
            @captured_output << data
            STDOUT.write(data) if interactive?
            fresh_output = data
          end
        end
      end

      # capture child's stderr and maybe proxy to STDERR
      if ready && ready.include?(@stderr)
        data = @stderr.readpartial(CHUNK) rescue nil
        if data
          data = @tap.call(:stderr, data) if @tap
          if data
            @captured_error << data
            STDERR.write(data) if interactive?
          end
        end
      end
      fresh_output
    rescue Interrupt
      # Proxy Ctrl+C to the child
      (Process.kill('INT', @pid) rescue nil) if @interactive
      raise
    end
  end
end
