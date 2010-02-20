module Delayed
  class Worker
    @@sleep_delay = 5
    
    cattr_accessor :sleep_delay

    cattr_accessor :logger
    self.logger = if defined?(Merb::Logger)
      Merb.logger
    elsif defined?(RAILS_DEFAULT_LOGGER)
      RAILS_DEFAULT_LOGGER
    end

    def initialize(options={})
      @quiet = options[:quiet]
      Delayed::Job.min_priority = options[:min_priority] if options.has_key?(:min_priority)
      Delayed::Job.max_priority = options[:max_priority] if options.has_key?(:max_priority)
    end

    def start
      say "*** Starting job worker #{Delayed::Job.worker_name}"

      trap('TERM') { say 'Exiting...'; $exit = true }
      trap('INT')  { say 'Exiting...'; $exit = true }

      loop do
        result = nil

        realtime = Benchmark.realtime do
          result = Delayed::Job.work_off
        end

        count = result.sum

        if count.zero?
          i = @@sleep_delay.to_f
          while i > 0
            break if $exit
            sleep(0.5)
            i = i - 0.5
          end
        else
          say "#{count} jobs processed at %.4f j/s, %d failed ..." % [count / realtime, result.last]
        end

        break if $exit
      end

    ensure
      Delayed::Job.clear_locks!
    end

    def say(text)
      puts text unless @quiet
      if logger
        logger.info text
        logger.flush if logger.respond_to?(:flush)
      end
    end

  end
end
