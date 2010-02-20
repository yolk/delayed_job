# Re-definitions are appended to existing tasks
task :environment
task :merb_env

namespace :jobs do
  desc "Clear the delayed_job queue."
  task :clear => [:merb_env, :environment] do
    Delayed::Job.delete_all
  end

  desc "Start a delayed_job worker."
  task :work => [:merb_env, :environment] do
    
    worker_name = "delayed_job.#{Rails.env}.#{ENV["DJ_WORKER_INDEX"] || Process.pid}"
    Delayed::Job.worker_name = "#{worker_name} #{Delayed::Job.worker_name}"
    Delayed::Worker.new(:min_priority => ENV['MIN_PRIORITY'], :max_priority => ENV['MAX_PRIORITY']).start
  end
end
