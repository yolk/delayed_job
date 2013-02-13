# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "delayed/version"

Gem::Specification.new do |s|
  s.name = %q{delayed_job}
  s.version = Delayed::VERSION
  s.authors = ["Sebastian Munz", "Brandon Keepers", "Tobias Luetke"]
  s.description = %q{Delayed_job (or DJ) encapsulates the common pattern of asynchronously executing longer tasks in the background. It is a direct extraction from Shopify where the job table is responsible for a multitude of core tasks.}
  s.email = %q{sebastian@yo.lk}
  s.homepage = %q{http://github.com/yolk/delayed_job}
  s.summary = %q{Database-backed asynchronous priority queue system -- Extracted from Shopify}

  s.files = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.add_dependency 'activerecord',        '>= 3.0.0'
  s.add_development_dependency 'rspec',   '>= 2.4.0'
  s.add_development_dependency 'sqlite3', '>= 1.3.5'
end

