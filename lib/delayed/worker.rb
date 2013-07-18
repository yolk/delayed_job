$exit

module Delayed
  class Worker
    @@sleep_delay = 5
    cattr_accessor :sleep_delay

    cattr_accessor :logger
    self.logger = if defined?(Rails)
      Rails.logger
    end

    def initialize(options={})
      @quiet = !!options[:quiet]
      Delayed::Job.min_priority = options[:min_priority] if options.has_key?(:min_priority)
      Delayed::Job.max_priority = options[:max_priority] if options.has_key?(:max_priority)
    end

    def start
      log "*** Starting job worker #{Delayed::Job.worker_name}"

      trap('TERM') { puts 'Shutting down after all aquired jobs finished...'; $exit = true }
      trap('INT')  { puts 'Shutting down after all aquired jobs finished...'; $exit = true }

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
          log "#{count} jobs processed at %.4f j/sec, %d failed ..." % [count / realtime, result.last]
        end

        break if $exit
      end

      log "Shutting down now!"

    ensure
      Delayed::Job.clear_locks!
    end

    def log(text)
      self.class.log(text, @quiet)
    end
    alias_method :say, :log # rpm compatibility

    def self.log(text, quiet=true)
      puts text unless quiet
      if logger
        logger.info "[#{Time.now}] #{text}"
        logger.flush if logger.respond_to?(:flush)
      end
    end

    def self.log_warn(text, quiet=true)
      puts text unless quiet
      if logger
        logger.warn "[#{Time.now}] #{text}"
        logger.flush if logger.respond_to?(:flush)
      end
    end

    def self.log_error(text, quiet=true)
      puts text unless quiet
      if logger
        logger.error "[#{Time.now}] #{text}"
        logger.flush if logger.respond_to?(:flush)
      end
    end

  end
end
