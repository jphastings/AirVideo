require 'net/http'
require 'stringio'

# == TODO
# * Potential bug: can you cd into a file?

module AirVideo
  # The AirVideo Client. At this stage it can emulate the iPhone app in all major features.
  #
  # Minor features, such as requesting a specific streams when using the Live Conversion feature aren't yet supported, but it's just a question 
  # of figuring out what the server is expecting.
  #
  # Setting #max_height and #max_width *should* be working with the Live Conversion, but for some reason it's not quite happening. Defaults are 640x480
  class Client
    attr_accessor :max_hieght, :max_width
    
    # Specify where your AirVideo Server lives. If your HTTP_PROXY environment variable is set, it will be honoured.
    #
    # At the moment I'm expecting ENV['HTTP_PROXY'] to have the form 'sub.domain.com:8080', I throw an http:// and bung it into URI.parse for convenience.
    #
    # I haven't currently worked out what the AirVideo salt is (or even confirmed that it is SHA1) so you'll need to snoop your own passwordDigest and pass it into the last term, or not use one for now.
    def initialize(server,port = 45631,password=nil)
      if ENV['HTTP_PROXY'].nil?
        @http = Net::HTTP
      else
        proxy = URI.parse("http://"+ENV['HTTP_PROXY'])
        @http = Net::HTTP::Proxy(proxy.host, proxy.port)
      end
      @endpoint = URI.parse "http://#{server}:#{port}/service"
      @passworddigest = password
      
      @req = Net::HTTP::Post.new(@endpoint.path)
      @req['User-Agent'] = 'AirVideo/2.2.4 CFNetwork/459 Darwin/10.0.0d3'
      @req['Accept'] = '*/*'
      @req['Accept-Language'] = 'en-us'
      @req['Accept-Encoding'] = 'gzip, deflate'
        
      @current_dir = "/"
      
      @max_width  = 640
      @max_height = 480
    end
    
    # Lists the folders and videos in the current directory as an Array of AirVideo::FileObject and AirVideo::FolderObject objects.
    def ls(dir = ".")
      dir = File.expand_path(dir,@current_dir)[1..-1]
      dir = nil if dir == ""
      #begin
        request("browseService","getItems",[dir])['result']['items'].collect do |hash|
          case hash.name
          when "air.video.DiskRootFolder", "air.video.ITunesRootFolder","air.video.Folder"
            FolderObject.new(self,hash['name'],hash['itemId'])
          when "air.video.VideoItem","air.video.ITunesVideoItem"
            FileObject.new(self,hash['name'],hash['itemId'],hash['detail'] || {})
          else
            raise NotImplementedError, "Unknown: #{hash.name}"
          end
        end
      #rescue NoMethodError
      #  raise RuntimeError, "This folder does not exist"
      #end
    end
    
    # Changes to the given directory. Will accept an AirVideo::FolderObject or a string.
    # Returns the AirVideo::Client instance, so you can string commands:
    #
    #     AirVideo::Client.new('127.0.0.1').ls[0].cd.ls
    #
    # NB. This will *not* check to see if the folder actually exists!
    def cd(dir)
      dir = dir.location if dir.is_a? FolderObject
      @current_dir = File.expand_path(dir,@current_dir)
      self
    end
    
    # Returns the streaming video URL for the given AirVideo::FileObject.
    def get_url(fileobj,liveconvert = false)
      raise NoMethodError, "Please pass a FileObject" if not fileobj.is_a? FileObject
      begin
        if liveconvert
          request("livePlaybackService","initLivePlayback",[conversion_settings(fileobj)])['result']['contentURL']
        else
          request("playbackService","initPlayback",[fileobj.location[1..-1]])['result']['contentURL']
        end
      rescue NoMethodError
        raise RuntimeError, "This video does not exist"
      end
    end
    
    # Returns the path to the current directory
    def pwd
      @current_dir
    end
    alias :getcwd :pwd
  
    def inspect
      "<AirVideo Connection: #{@endpoint.host}:#{@endpoint.port}>"
    end
  
    private
    def conversion_settings(fileobj)
      video = {}
      fileobj.details['streams'].each do |stream|
        if stream['streamType'] == 0
          video = stream
          break
        end
      end
      scaling = [video['width'] / @max_width, video['height'] / @max_height]
      if scaling.max > 1.0
        video['width'] = video['width'] / scaling.max
        video['height'] = video['height'] / scaling.max
      end
      
      # TODO: fill these in correctly
      AvMap::Hash.new("air.video.ConversionRequest", {
        "itemId" => fileobj.location[1..-1],
        "audioStream"=>1,
        "allowedBitrates"=> BitrateList["512", "768", "1536", "1024", "384", "1280", "256"],
        "audioBoost"=>0.0,
        "cropRight"=>0,
        "cropLeft"=>0,
        "resolutionWidth"=>video['width'],
        "videoStream"=>0,
        "cropBottom"=>0,
        "cropTop"=>0,
        "quality"=>0.699999988079071,
        "subtitleInfo"=>nil,
        "offset"=>0.0,
        "resolutionHeight"=>video['height']
      })
    end
    
    def request(service,method,params)
      avrequest = {
        "requestURL" => @endpoint.to_s,
        "clientVersion" =>221,
        "serviceName" => service,
        "methodName" => method,
        # TODO: Figure out what this is!
        "clientIdentifier" => "89eae483355719f119d698e8d11e8b356525ecfb",
        "parameters" =>params
      }
      avrequest['passwordDigest'] = @passworddigest if not @passworddigest.nil?
      
      @req.body = AvMap::Hash.new("air.connect.Request", avrequest).to_avmap
      
      @http.start(@endpoint.host,@endpoint.port) do |http|
        res = http.request(@req)
        AvMap.parse StringIO.new(res.body)
      end
    end
    
    # Represents a folder as listed by the AirVideo server.
    #
    # Has helper functions like #cd which will move the current directory of the originating AirVideo::Client instance to this folder.
    class FolderObject
      attr_reader :name, :location

      # Shouldn't be used outside of the AirVideo module
      def initialize(server,name,location)
        @server = server
        @name = name
        @location = "/"+location
      end

      # A helper method that will move the current directory of the AirVideo::Client instance to this FolderObject.
      def cd
        @server.cd(self)
      end

      def inspect
        "<Folder: #{(name.nil?) ? "/Unknown/" : name}>"
      end
    end

    # Represents a video file as listed by the AirVideo server.
    #
    # Has helper functions like #url and #live_url which give the video playback URLs of this video, as produced by the originating AirVideo::Client instance's AirVideo::Client.get_url method.
    class FileObject
      attr_reader :name, :location, :details

      def initialize(server,name,location,detail = {})
        @server = server
        @name = name
        @location = "/"+location
        @details = detail
      end

      # Gives the URL for direct video playback
      def url
        @server.get_url(self,false)
      end

      # Gives the URL for live conversion video playback
      def live_url
        @server.get_url(self,true)
      end

      def inspect
        "<Video: #{name}>"
      end
    end
  end
  
  # A two-way parser for AirVideo's communication protocol.
  #
  #     s = "Hello World!".to_avmap
  #     # => "s\000\000\000\012Hello World!"
  #     p AvMap.parse(s)
  #     # => "Hello World!"
  #
  module AvMap
    # Expects an IO object. I use either a file IO or a StringIO object here.
    def self.parse(stream)
      @input = stream
      self.read_identifier
    end

    private
    def self.read_identifier(depth = 0)
      begin
        ident = @input.read(1)
        case ident
        when "o" # Hash
          unknown = @input.read(4).unpack("N")[0]
          hash = Hash.new(@input.read(@input.read(4).unpack("N")[0]), {})
          unknown = @input.read(4).unpack("N")[0]
          num_els = @input.read(4).unpack("N")[0]
          #$stderr.puts "#{" "*depth}Hash: #{arr_name} // #{num_els} times"
          1.upto(num_els) do |iter|
            hash_item = @input.read(@input.read(4).unpack("N")[0])
            #$stderr.puts "#{" "*depth}-#{arr_name}:#{iter} - #{hash_item}"
            hash[hash_item] = self.read_identifier(depth + 1)
          end
          hash
        when "s" # String
          #$stderr.puts "#{" "*depth}String"
          unknown = @input.read(4).unpack("N")[0]
          @input.read(@input.read(4).unpack("N")[0])
        when "i" # Integer?
          #$stderr.puts "#{" "*depth}Integer"
          @input.read(4).unpack("N")[0]
        when "a","e" # Array
          #$stderr.puts "#{" "*depth}Array"
          unknown = @input.read(4).unpack("N")[0]
          num_els = @input.read(4).unpack("N")[0]
          arr = []
          1.upto(num_els) do |iter|
            arr.push self.read_identifier(depth + 1)
          end
          arr
        when "n" # nil
          #$stderr.puts "#{" "*depth}Nil"
          nil
        when "f" # Float?
          @input.read(8).unpack('G')[0]
        when "l" # Big Integer
          @input.read(8).unpack("NN").reverse.inject([0,0]){|res,el| [res[0] + (el << (32 * res[1])),res[1] + 1]}[0]
        when "r" # Integer?
          #$stderr.puts "#{" "*depth}R?"
          @input.read(4).unpack("N")[0]
        when "x" # Binary Data
          #$stderr.puts "#{" "*depth}R?"
          unknown = @input.read(4).unpack("N")[0]
          BinaryData.new @input.read(@input.read(4).unpack("N")[0])
        else
          raise NotImplementedError, "I don't know what to do with the '#{ident}' identifier"
        end
      rescue Exception => e
        puts e.message  
        puts "Error : #{@input.tell}"
        p e.backtrace
        Process.exit
      end
    end

    # Just hack in an addition to the Hash object, we need to be able to give each hash a name to make everything a little simpler.
    class Hash < Hash
      attr_accessor :name

      # Create a new Hash with a name. Yay!
      def initialize(key,hash)
        super()
        @name = key
        merge! hash
        self
      end
      
      def inspect
        @name+super
      end
    end

    # A simple container for Binary Data. With AirVideo this is used to hold thumbnail JPG data.
    class BinaryData
      attr_reader :data

      # Not to be used outside of the AvMap module
      def initialize(data)
        @data = data
      end

      # Writes the data to the given filename
      #
      # TODO: LibMagic to detect what the extension should be?
      def write_to(filename)
        open(filename,"w") do |f|
          f.write @data
        end
      end

      def inspect
        "<Data: #{data.length} bytes>"
      end
    end

    # In order to demand that an array be classified with the 'e' header, rather than the 'a' header, use a BitrateList array.
    #
    # I'm not certain that this is the only place the 'e' arrays are used, but they're definitely used for Bitrate Lists. So this is called the BitrateList. Yup.
    class BitrateList < Array; end
  end
end

# Add the #to_avmap method for ease of use in the Client
class Object
  # Will convert an object into an AirVideo map, if the object and it's contents are supported
  def to_avmap(reset_counter = true)
    $to_avmap_counter = 0 if reset_counter
    
    case self
    when Array
      letter = (self.is_a? AirVideo::AvMap::BitrateList) ? "e" : "a"
      self.push nil if self.length == 0 # Must have at least one entry in the hash, I think
      "#{letter}#{[($to_avmap_counter += 1) - 1].pack("N")}#{[self.length].pack("N")}"+self.collect do |item|
        item.to_avmap(false)
      end.join
    when AirVideo::AvMap::Hash
      version = case self.name
      when "air.video.ConversionRequest"
        221
      else
        1
      end
      "o#{[($to_avmap_counter += 1) - 1].pack("N")}#{[self.name.length].pack("N")}#{self.name}#{[version].pack("N")}#{[self.length].pack("N")}"+self.to_a.collect do |key,val|
        "#{[key.length].pack("N")}#{key}"+val.to_avmap(false)
      end.join
    when String
      "s#{[($to_avmap_counter += 1) - 1].pack("N")}#{[self.length].pack("N")}#{self}"
    when NilClass
      "n"
    when Integer
      "i#{[self].pack('N')}"
    when Float # unsure of this is what this is meant to be
      "f#{[self].pack('G')}"
    else
      raise NotImplementedError, "Can't turn a #{self.class} into an avmap"
    end
  end
end