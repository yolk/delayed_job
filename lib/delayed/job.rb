require 'timeout'

module Delayed

  class DeserializationError < StandardError
  end

  # A job object that is persisted to the database.
  # Contains the work object as a YAML field.
  class Job < ActiveRecord::Base
    @@max_attempts = 25
    @@max_run_time = 4.hours
    
    cattr_accessor :max_attempts, :max_run_time
    
    set_table_name :delayed_jobs

    # By default failed jobs are destroyed after too many attempts.
    # If you want to keep them around (perhaps to inspect the reason
    # for the failure), set this to false.
    cattr_accessor :destroy_failed_jobs
    self.destroy_failed_jobs = true
    
    # Every job has a unique key which you can pass to the user (javascript) without
    # alowing him to quess subsequent keys.
    before_create do |job|
      job.unique_key ||= (defined?(::SecureRandom) ? ::SecureRandom : ActiveSupport::SecureRandom).hex(10)
    end
    
    # Every worker has a unique name which by default is the pid of the process.
    # There are some advantages to overriding this with something which survives worker retarts:
    # Workers can safely resume working on tasks which are locked by themselves. The worker will assume that it crashed before.
    cattr_accessor :worker_name
    self.worker_name = "host:#{Socket.gethostname}" rescue "host:unknown"

    NextTaskSQL         = '(run_at <= ? AND (locked_at IS NULL OR locked_at < ?) OR (locked_by = ?)) AND state IS NULL'
    NextTaskOrder       = 'priority DESC, run_at ASC'

    ParseObjectFromYaml = /\!ruby\/\w+\:([^\s]+)/

    cattr_accessor :min_priority, :max_priority
    self.min_priority = nil
    self.max_priority = nil

    # When a worker is exiting, make sure we don't have any locked jobs.
    def self.clear_locks!
      update_all("locked_by = null, locked_at = null", ["locked_by = ?", worker_name])
    end
    
    def failed?
      state == "failed"
    end
    
    def successful?
      state == "successful"
    end
    
    def payload_object
      @payload_object ||= deserialize(self['handler'])
    end

    def name
      @name ||= begin
        payload = payload_object
        if payload.respond_to?(:display_name)
          payload.display_name
        else
          payload.class.name
        end
      end
    end

    def payload_object=(object)
      self.handler = object.to_yaml
    end
    
    def result=(data)
      write_attribute(:result, data.to_yaml)
    end
    
    def result
      YAML.load(read_attribute(:result)) rescue ""
    end
    alias_method :last_error, :result

    # Reschedule the job in the future (when a job fails).
    # Uses an exponential scale depending on the number of failed attempts.
    def reschedule(message, backtrace = [], time = nil)
      if (self.attempts += 1) < max_attempts
        self.run_at     = time || Job.db_time_now + (attempts ** 4) + 5
        self.result     = message + "\n" + backtrace.join("\n")
        self.unlock
        save!
      else
        if destroy_failed_jobs
          Delayed::Worker.log "* [JOB #{name}] PERMANENTLY removing because of #{attempts} failures."
          destroy
        else
          Delayed::Worker.log "* [JOB #{name}] Giving up after #{attempts} failures."
          failed!
        end
      end
    end

    # Try to run one job. Returns true/false (work done/work failed) or nil if job can't be locked.
    def run_with_lock(max_run_time, worker_name)
      Delayed::Worker.log "* [JOB #{name}] Acquiring lock"
      unless lock_exclusively!(max_run_time, worker_name)
        # We did not get the lock, some other worker process must have
        Delayed::Worker.log_warn "* [JOB #{name}] Failed to acquire exclusive lock"
        return nil # no work done
      end

      begin
        runtime = Benchmark.realtime do
          returned = Timeout.timeout(max_run_time.to_i) { invoke_job }
          if payload_object.respond_to?(:keep_job_after_success?) && payload_object.keep_job_after_success?
            self.result = returned
            successful!
          else
            destroy
          end
        end
        Delayed::Worker.log "* [JOB #{name}] Completed and #{self.successful? ? 'kept' : 'removed'} after %.4f sec" % runtime
        return true  # did work
      rescue Exception => e
        reschedule e.message, e.backtrace
        log_exception(e)
        return false  # work failed
      end
    end

    # Add a job to the queue
    def self.enqueue(*args, &block)
      object = block_given? ? EvaledJob.new(&block) : args.shift

      unless object.respond_to?(:perform) || block_given?
        raise ArgumentError, 'Cannot enqueue items which do not respond to perform'
      end
    
      priority = args.first || 0
      run_at   = args[1]

      Job.create(:payload_object => object, :priority => priority.to_i, :run_at => run_at)
    end

    # Find a few candidate jobs to run (in case some immediately get locked by others).
    def self.find_available(limit = 5, max_run_time = max_run_time)

      time_now = db_time_now

      sql = NextTaskSQL.dup

      conditions = [time_now, time_now - max_run_time, worker_name]

      if self.min_priority
        sql << ' AND (priority >= ?)'
        conditions << min_priority
      end

      if self.max_priority
        sql << ' AND (priority <= ?)'
        conditions << max_priority
      end

      conditions.unshift(sql)

      ActiveRecord::Base.silence do
        find(:all, :conditions => conditions, :order => NextTaskOrder, :limit => limit)
      end
    end

    # Run the next job we can get an exclusive lock on.
    # If no jobs are left we return nil
    def self.reserve_and_run_one_job(max_run_time = max_run_time)

      # We get up to 5 jobs from the db. In case we cannot get exclusive access to a job we try the next.
      # this leads to a more even distribution of jobs across the worker processes
      find_available(5, max_run_time).each do |job|
        t = job.run_with_lock(max_run_time, worker_name)
        return t unless t == nil  # return if we did work (good or bad)
      end

      nil # we didn't do any work, all 5 were not lockable
    end

    # Lock this job for this worker.
    # Returns true if we have the lock, false otherwise.
    def lock_exclusively!(max_run_time, worker = worker_name)
      now = self.class.db_time_now
      affected_rows = if locked_by != worker
        # We don't own this job so we will update the locked_by name and the locked_at
        self.class.update_all(["locked_at = ?, locked_by = ?", now, worker], ["id = ? and (locked_at is null or locked_at < ?) and (run_at <= ?)", id, (now - max_run_time.to_i), now])
      else
        # We already own this job, this may happen if the job queue crashes.
        # Simply resume and update the locked_at
        self.class.update_all(["locked_at = ?", now], ["id = ? and locked_by = ?", id, worker])
      end
      if affected_rows == 1
        self.locked_at    = now
        self.locked_by    = worker
        return true
      else
        return false
      end
    end

    # Unlock this job (note: not saved to DB)
    def unlock
      self.locked_at    = nil
      self.locked_by    = nil
    end

    # This is a good hook if you need to report job processing errors in additional or different ways
    def log_exception(error)
      on_exception(error)
      Delayed::Worker.log_error "* [JOB #{name}] Failed with #{error.class.name}: #{error.message} - #{attempts} of #{max_attempts} attempts"
    end
    
    # Exception hook
    def on_exception(error);end

    # Do num jobs and return stats on success/failure.
    # Exit early if interrupted.
    def self.work_off(num = 100)
      success, failure = 0, 0

      num.times do
        case self.reserve_and_run_one_job
        when true
            success += 1
        when false
            failure += 1
        else
          break  # leave if no work could be done
        end
        break if $exit # leave if we're exiting
      end

      return [success, failure]
    end

    # Moved into its own method so that new_relic can trace it.
    def invoke_job
      payload_object.perform
    end
    
  private

    def deserialize(source)
      handler = YAML.load(source) rescue nil

      unless handler.respond_to?(:perform)
        if handler.nil? && source =~ ParseObjectFromYaml
          handler_class = $1
        end
        attempt_to_load(handler_class || handler.class)
        handler = YAML.load(source)
      end
      
      handler.delayed_job_key = unique_key if handler.respond_to?(:delayed_job_key=)

      return handler if handler.respond_to?(:perform)

      raise DeserializationError,
        'Job failed to load: Unknown handler. Try to manually require the appropriate file.'
    rescue ArgumentError, TypeError, LoadError, NameError => e
      raise DeserializationError,
        "Job failed to load: #{e.message}. Try to manually require the required file."
    end

    # Constantize the object so that ActiveSupport can attempt
    # its auto loading magic. Will raise LoadError if not successful.
    def attempt_to_load(klass)
       klass.constantize
    end

    # Get the current time (GMT or local depending on DB)
    # Note: This does not ping the DB to get the time, so all your clients
    # must have syncronized clocks.
    def self.db_time_now
      (ActiveRecord::Base.default_timezone == :utc) ? Time.now.utc : Time.zone.now
    end
    
    # Use handler-specific max_attempts before giving up.
    # Uses Delayed::Job::max_attempts when not defined on handler
    def max_attempts
      (payload_object.class::max_attempts rescue nil) || self.class.max_attempts
    end
    
    def failed!
      self.state = "failed"
      save!
    end
    
    def successful!
      self.state = "successful"
      save!
    end
    
  protected

    before_save :set_run_at, :guard_state
    
    def set_run_at
      self.run_at ||= self.class.db_time_now
    end
    
    def guard_state
      if failed? || successful?
        self.completed_at = self.class.db_time_now if state_changed?
      else
        self.state = nil
        self.completed_at = nil
      end
    end
  end

  class EvaledJob
    def initialize
      @job = yield
    end

    def perform
      eval(@job)
    end
  end
end
