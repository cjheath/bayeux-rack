require 'rubygems'
require 'rake'

require 'jeweler'
require './lib/bayeux'

Jeweler::Tasks.new do |gem|
  gem.name = "bayeux-rack"
  gem.version = Bayeux::VERSION
  gem.homepage = "http://github.com/cjheath/bayeux-rack"
  gem.license = "MIT"
  gem.summary = %Q{Bayeux (COMET or long-polling) protocol server as a Sinatra application}
  gem.description = %Q{
Bayeux (COMET or long-polling) protocol server as a Sinatra application.
Light weight and high scalability are achieved by using the
asynchronous Rack extensions added to Thin by async_sinatra.}
  gem.email = %w[clifford.heath@gmail.com]
  gem.authors = ["Clifford Heath"]
  gem.add_runtime_dependency 'json', '>= 1.4.6'
  gem.add_runtime_dependency 'async_sinatra', '> 0.1'
  gem.add_runtime_dependency 'eventmachine', '>= 0.12'
  gem.add_runtime_dependency 'thin', '>= 1.2'
  #  gem.add_development_dependency 'rspec', '> 1.2.3'
end
Jeweler::RubygemsDotOrgTasks.new

require 'rake/testtask'
Rake::TestTask.new(:test) do |test|
  test.libs << 'lib' << 'test'
  test.pattern = 'test/**/test_*.rb'
  test.verbose = true
end
task :default => :test

require 'rdoc/task'
Rake::RDocTask.new do |rdoc|
  rdoc.rdoc_dir = 'rdoc'
  rdoc.title = "bayeux-rack #{Bayeux::VERSION}"
  rdoc.rdoc_files.include('README.rdoc')
  # rdoc.rdoc_files.include('History.rdoc')
  rdoc.rdoc_files.include('lib/**/*.rb')
end

desc 'Generate website files'
task :website_generate do
  sh %q{ruby script/txt2html website/index.txt > website/index.html}
end

desc 'Upload website files via rsync'
task :website_upload do
  local_dir  = 'website'
  website_config = YAML.load(File.read("config/website.yml"))
  host       = website_config["host"]
  host       = host ? "#{host}:" : ""
  remote_dir = website_config["remote_dir"]
  sh %{rsync -aCv #{local_dir}/ #{host}#{remote_dir}}
end

