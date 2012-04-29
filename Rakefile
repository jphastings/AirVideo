require 'rubygems'
require 'rake'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "airvideo-ng"
    gem.summary = %Q{Allows communication with an AirVideo server}
    gem.description = %Q{Communicate with an AirVideo server, even through a proxy: Retrieve the streaming URLs for your videos.}
    gem.email = "regis.despres+rubygem@gmail.com"
    gem.homepage = "http://github.com/kalw/AirVideo"
    gem.authors = ["Kalw forked from JP Hastings"]
    # gem is a Gem::Specification... see http://www.rubygems.org/read/chapter/20 for additional settings
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler (or a dependency) not available. Install it with: sudo gem install jeweler"
end

task :default => :build
