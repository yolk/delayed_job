class CreateDelayedJobs < ActiveRecord::Migration
  def self.up
    create_table :delayed_jobs, :force => true do |table|
      table.integer  :priority, :default => 0      # Allows some jobs to jump to the front of the queue
      table.integer  :attempts, :default => 0      # Provides for retries, but still fail eventually.
      table.text     :handler                      # YAML-encoded string of the object that will do work
      table.text     :result
      table.datetime :run_at                       # When to run. Could be Time.zone.now for immediately, or sometime in the future.
      table.datetime :locked_at                    # Set when a client is working on this object
      table.string   :locked_by                    # Who is working on this object (if locked)
      table.string   :unique_key
      table.datetime :completed_at
      table.string   :state, :default => nil
      table.timestamps
    end

  end
  
  def self.down
    drop_table :delayed_jobs  
  end
end