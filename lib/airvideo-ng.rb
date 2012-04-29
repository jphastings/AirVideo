require 'net/http'
require 'stringio'
require 'digest/sha1'

# == TODO
# * Potential bug: can you cd into a file?
# * Caching for details?
#   - Active-record?
#   - In-memory by default

module AirVideo
  # The AirVideo Client. At this stage it can emulate the iPhone app in all major features.
  #
  # Minor features, such as requesting a specific streams when using the Live Conversion feature aren't yet supported, but it's just a question 
  # of figuring out what the server is expecting.
  #
  # Setting #max_height and #max_width *should* be working with the Live Conversion, but for some reason it's not quite happening. Defaults are 640x480
  class Client
    attr_accessor :max_height, :max_width
    attr_reader :proxy
    
    # Specify where your AirVideo Server lives. If your HTTP_PROXY environment variable is set, it will be honoured.
    #
    # At the moment I'm expecting ENV['HTTP_PROXY'] to have the form 'sub.domain.com:8080', I throw an http:// and bung it into URI.parse for convenience.
    def initialize(server,port = 45631,password=nil)
      set_proxy # Set to environment proxy settings, if applicable
      @endpoint = URI.parse "http://#{server}:#{port}/service"
      @passworddigest = Digest::SHA1.hexdigest("S@17" + password + "@1r").upcase if !password.nil?
      @req = Net::HTTP::Post.new(@endpoint.path)
      @req['User-Agent'] = 'AirVideo/2.4.1 CFNetwork/485.10.2 Darwin/10.3.1'
      @req['Accept'] = '*/*'
      @req['Accept-Language'] = 'en-us'
      @req['Accept-Encoding'] = 'gzip, deflate'
	  @req['Connection'] = 'keep-alive'
        
      @current_dir = "/"
      
      @max_width  = 640
      @max_height = 480
    end
    
    # Potentially confusing: 
    # * Sending 'server:port' will use that address as an HTTP proxy
    # * An empty string (or something not recognisable as a URL with http:// put infront of it) will try to use the ENV['HTTP_PROXY'] variable
    # * Sending nil or any object that can't be parsed to a string will remove the proxy
    #
    # NB. You can access the @proxy URI object externally, but changing it will *not* automatically call set_proxy
    def set_proxy(proxy_server_and_port = "")
      begin
        @proxy = URI.parse("http://"+((proxy_server_and_port.empty?) ? ENV['HTTP_PROXY'] : string_proxy))
        @http = Net::HTTP::Proxy(@proxy.host, @proxy.port)
      rescue
        @proxy = nil
        @http = Net::HTTP
      end
    end
    
	
    # Lists the folders and videos in the current directory as an Array of AirVideo::VideoObject and AirVideo::FolderObject objects.
    def ls(dir = ".")
      dir = dir.location if dir.is_a? FolderObject
      dir = File.expand_path(dir,@current_dir)[1..-1]
      dir = nil if dir == ""

      begin
        request("browseService","getItems",[browse_settings(dir)])['result']['items'].collect do |hash|
		  #print "browsServere:getItems:\n"
		  #hash.each {|key, value| puts "key = #{key}, value = #{value}\n" }
	
          case hash.name
          when "air.video.DiskRootFolder", "air.video.ITunesRootFolder","air.video.Folder"
            FolderObject.new(self,hash['name'],hash['itemId'])
          when "air.video.VideoItem","air.video.ITunesVideoItem"
            VideoObject.new(self,hash['name'],hash['itemId'],hash['detail'] || nil)
          else
            raise NotImplementedError, "Unknown: #{hash.name}"
          end
        end
      rescue NoMethodError
        raise RuntimeError, "This folder does not exist dir = #{dir}\n"
      end
    end
	
	def browse_settings(dir)
		AvMap::Hash.new("air.video.BrowseRequest",{
			"folderId"=>dir,			
			"sortField"=>0,				
			"sortDirection"=>0,			
			"filterOriginalItems"=>0,	
			"metaData"=>nil,				
			"preloadDetails"=>0				
	   })
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
    
	
	def close_Playback(playback,service,method)
		results = request(service.to_s,method.to_s,[playback.to_s])['result']
		return results
	end
	
    # Returns the streaming video URL for the given AirVideo::VideoObject.
    def get_url(videoobj,liveconvert = false)
      raise NoMethodError, "Please pass a VideoObject" if not videoobj.is_a? VideoObject
 
      begin
        if liveconvert
		  details = videoobj.details
		  cs = conversion_settings(videoobj)
          results = request("livePlaybackService","initLivePlayback",[cs])['result']['contentURL']

		  return results
        else
          request("playbackService","initPlayback",[videoobj.location[1..-1]])['result']['contentURL']
        end
      rescue NoMethodError
        raise RuntimeError, "This video does not exist"
      end
    end
	

	def getConversionLocation()
		res = convertVideoRequest("conversionService","getConversionLocations",nil)
		return res
	end
	
	
	def convertVideoRequest(service,method,params)
	  #print "PARAMS:\n"
	  #params[0].each {|key, value| print "		#{key} = #{value}\n"}
	  
      avrequest = {
        "requestURL" => @endpoint.to_s,
        "clientVersion" =>240,
        "serviceName" => service,
        "methodName" => method,
		"clientIdentifier" => "5e8ddc669b2098b0e3dcae5aa1d19338e517544f",
        "parameters" =>params
      }
      avrequest['passwordDigest'] = @passworddigest if not @passworddigest.nil?
	  
	  print "AVREQUEST:\n"
	  avrequest.each {|key, value| print "		#{key} = #{value}\n"}
	  
      @req.body = AvMap::Hash.new("air.connect.Request", avrequest).to_avmap

	  print "@REQ.BODY:\n"
	  @req.body.each {|key, value| print "	#{key} = #{value}\n"}
	  
      @http.start(@endpoint.host,@endpoint.port) do |http|
        res = http.request(@req)
		parse = AvMap.parse StringIO.new(res.body)
		return parse
      end
    end

	def convertVideo(videoobj)
		raise NoMethodError, "Please pass a VideoObject" if not videoobj.is_a? VideoObject

		begin
			# don't remove call to details, if you do convertVideo will ot work
			details = videoobj.details
			location = getConversionLocation()
			print "location = #{location}\n"
			cs = conversion_settings(videoobj)
		
		
	        metaData = 	AvMap::Hash.new("metaData",{
									"device"=>"iPhone",
									"clientVersion"=>"2.4.1"
									})
							
			cs['metaData'] = metaData

			print "metaData = ",cs['metaData'].each {|key, value| print "#{key} = #{value}\n"},"\n"
			print "cs = #{cs}\n"
			
			#sleep 2
			result = convertVideoRequest("conversionService","convertItem",[cs])
			print "result = #{result}\n"
			return result 
		rescue NoMethodError
			raise RuntimeError, "Not able to convert video"
		end	
	end
	
	def get_pin(p)
		begin
		  pin = Array.new()
		  pin.push(p)
		  pin_request("trackerService","getServerState",pin)['result']
		rescue NoMethodError
		  raise NoMethodError, "Could not get pin for server\n"
		rescue => ex
		  raise ex,"Some sort of error\n"
	    end	  
	end
    
    def get_details(items)
      items = [items] if !items.is_a? Array
      items.collect! do |item|
        case item
        when VideoObject
          item.location[1..-1]
        when String
          item
        end
      end.compact!
      
      request("browseService","getItemsWithDetail",[items])['result'][0]
    end
    
    # Searches the current directory for items matching the given regular expression
    def search(re_string,dir=".")
      # Get the directory we're searching
      dir = File.expand_path((dir.is_a? FolderObject) ? dir.location : dir,@current_dir)
      ls(dir).select {|item| item.name =~ %r{#{re_string}}}
    end
    
    # Returns the path to the current directory
    def pwd
      @current_dir
    end
    alias :getcwd :pwd
  
    def inspect
      "<AirVideo Connection: #{@endpoint.host}:#{@endpoint.port}>"
    end
  
    #private
    def conversion_settings(videoobj)
      video = videoobj.video_stream
      scaling = [video['width'] / @max_width, video['height'] / @max_height]

      if scaling.max > 1.0
        video['width'] = (video['width'] / scaling.max).to_i
        video['height'] = (video['height'] / scaling.max).to_i
      end
	  
      # TODO: fill these in correctly
      AvMap::Hash.new("air.video.ConversionRequest", {
	    "resolutionWidth"=>video['width'],
		"resolutionHeight"=>video['height'],
		"cropLeft"=>0,
		"cropRight"=>0,
		"cropTop"=>0,
		"cropBottom"=>0,
        "itemId" => videoobj.location[1..-1],
		"offset"=>0.0,
		"quality"=>0.699999988079071,
		"videoStream"=>0,#video['index'],
        "audioStream"=>1,#videoobj.audio_stream['index'],
		"subtitleInfo"=>nil,
		"audioBoost"=>0.0,
        "allowedBitratesLocal"=> AirVideo::AvMap::BitrateList["1536"],
		"allowedBitratesRemote"=> AirVideo::AvMap::BitrateList["384"]
      })
    end
    	
	def pin_request(service,method,params)
		server = "inmethod.com"
		port = "1112"
		pin_endpoint = URI.parse "http://#{server}:#{port}/service"

		avrequest = {
			"requestURL" => pin_endpoint.to_s,
			"clientVersion" =>100,
			"serviceName" => service,
			"methodName" => method,
			"parameters" => params,
			#"clientIdentifier" => "89eae483355719f119d698e8d11e8b356525ecfb",
			"clientIdentifier" => "5e8ddc669b2098b0e3dcae5aa1d19338e517544f",
			"passwordDigest" => nil
		}	
		
		req = Net::HTTP::Post.new(pin_endpoint.path)
		req['User-Agent'] = 'AirVideo/2.4.1 CFNetwork/485.10.2 Darwin/10.3.1'
		req['Accept'] = '*/*'
		req['Accept-Language'] = 'en-us'
		req['Accept-Encoding'] = 'gzip, deflate'
		req['Connection'] = 'keep-alive'
		
		req.body = AvMap::Hash.new("air.connect.Request", avrequest).to_avmap
		
		http = Net::HTTP
		
		http.start(pin_endpoint.host, pin_endpoint.port) do |http|
			res = http.request(req)
			AvMap.parse StringIO.new(res.body)
		end			
	end
	
    def request(service,method,params)
      avrequest = {
        "requestURL" => @endpoint.to_s,
        "clientVersion" =>240,
        "serviceName" => service,
        "methodName" => method,
        # TODO: Figure out what this is!
        #"clientIdentifier" => "89eae483355719f119d698e8d11e8b356525ecfb",
		"clientIdentifier" => "5e8ddc669b2098b0e3dcae5aa1d19338e517544f",
        "parameters" =>params
      }
      avrequest['passwordDigest'] = @passworddigest if not @passworddigest.nil?

      @req.body = AvMap::Hash.new("air.connect.Request", avrequest).to_avmap

      @http.start(@endpoint.host,@endpoint.port) do |http|
        res = http.request(@req)
		parse = AvMap.parse StringIO.new(res.body)
		return parse
      end
    end
    
    # Represents a folder as listed by the AirVideo server.
    #
    # Has helper functions like #cd which will move the current directory of the originating AirVideo::Client instance to this folder.
    class FolderObject
      attr_reader :name, :location
      Helpers = [:cd, :ls, :search]

      # Shouldn't be used outside of the AirVideo module
      def initialize(server,name,location) # :nodoc:
        @server = server
        @name = name
        @location = "/"+location
      end

      def inspect
        "<Folder: #{(name.nil?) ? "/Unknown/" : name}>"
      end
      
      def cd
        @server.cd(self)
      end
      
      def ls
        @server.ls(self)
      end
      
      def search(re_string)
        @server.search(re_string,self)
      end
    end

    # Represents a video file as listed by the AirVideo server.
    #
    # Has helper functions like #url and #live_url which give the video playback URLs of this video, as produced by the originating AirVideo::Client instance's AirVideo::Client.get_url method.
    class VideoObject
      attr_reader :name, :location, :details, :streams
      attr_accessor :audio_stream, :video_stream

      # Shouldn't be used outside of the AirVideo module
      def initialize(server,name,location,detail = nil) # :nodoc:
        @server = server
        @name = name
        @location = "/"+location
        @details = detail # nil implies the details haven't been loaded
        # These are the defaults, all videos *should* have these.
        @video_stream = {'index' => 1}
        @audio_stream = {'index' => 0}
        details if !@details.nil?
      end
      
      def details
		#print "####### In airvideo details #######\n"
        @details = @server.get_details(self)
        #print "###########  @details = #{@details}\n"
		######dump attributes of hash
		#@details.each {|key, value| puts "#{key} = #{value}\n"}
        if !@details.nil?
          @streams = {'video' => [],'audio' => [],'unknown' => []}
		  #print "@streams = #{@streams}\n"
		  #print "@details['detail'] = ",@details['detail'],"\n"
          @details['detail']['streams'].each do |stream|
            @streams[case
            when 0
              "video"
            when 1
              "audio"
            else
              "unknown"
            end
            ]
          end
		  
          @audio_stream = @details['detail']['streams'][0]
		  #print "@audio_stream = #{@audio_stream}\n"
          @video_stream = @details['detail']['streams'][0]
		  #print "@video_stream = #{@video_stream}\n"
        end
        @details
      end
      
      # Checks to see if this video has that audio stream index, then changes internal settings so that live conversions will use this stream.
      def audio_stream=(stream_hash_or_index)
        index = stream_hash_or_index['index'] rescue stream_hash_or_index
        get_details if @details.nil?
        raise RuntimeError, "Couldn't retrieve video details" if @details.nil?
        raise RuntimeError, "No such audio stream" if @streams['audio'].collect{|stream| stream['index']}.include? index
        @audio_stream = index
      end
      
      # Checks to see if this video has that video stream index, then changes internal settings so that live conversions will use this stream.
      def video_stream=(stream_hash_or_index)
        index = stream_hash_or_index['index'] rescue stream_hash_or_index
        get_details if @details.nil?
        raise RuntimeError, "Couldn't retrieve video details" if @details.nil?
        raise RuntimeError, "No such audio stream" if @streams['video'].collect{|stream| stream['index']}.include? index
        @video_stream = index
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
      ident = @input.read(1)
      case ident
      when "o" # Hash
        unknown = @input.read(4).unpack("N")[0]
        hash = Hash.new(@input.read(@input.read(4).unpack("N")[0]), {})
        unknown = @input.read(4).unpack("N")[0]
        num_els = @input.read(4).unpack("N")[0]
        #$stderr.puts "#{" "*depth}Hash: #{unknown} // #{num_els} times"
        1.upto(num_els) do |iter|
          hash_item = @input.read(@input.read(4).unpack("N")[0])
          #$stderr.puts "#{" "*depth}-#{unknown}:#{iter} - #{hash_item}"
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

      # Not really useful outside of the AvMap module
      def initialize(data) # :nodoc:
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
      
      def length
        @data.length
      end

      def inspect
        "<Data: #{@data.length} bytes>"
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
    @@to_avmap_counter = 0 if reset_counter
    case self
	when Array
      letter = (self.is_a? AirVideo::AvMap::BitrateList) ? "e" : "a"
      self.push nil if self.length == 0 # Must have at least one entry in the hash, I think
      "#{letter}#{[(@@to_avmap_counter += 1) - 1].pack("N")}#{[self.length].pack("N")}"+self.collect do |item|
        item.to_avmap(false)
      end.join
    when AirVideo::AvMap::Hash
      version = case self.name
      when "air.video.ConversionRequest"
        240
	  when "air.video.BrowseRequest"
	    240
      else
        1
      end

# Implement metaData:
#						:length			:type
#					"\000\000\000\010"+"metaData"+
#				  :data       :counter     :number of items
#					"d"+"\000\000\000\015"+"\000\000\000\002"+
#						:string	:counter		 :length of str  :string value
#						"s"+"\000\000\000\016"+"\000\000\000\006"+"device"+
#						"s"+"\000\000\000\017"+"\000\000\000\006"+"iPhone"+
#						"s"+"\000\000\000\020"+"\000\000\000\015"+"clientVersion"+
#						"s"+"\000\000\000\021"+"\000\000\000\005"+"2.4.1"
#					:nil:integer   value
#						"ni"+"\000\000\000\000"  'nili0000'
		
#iphone (working):
#                                        00 00 00 08 6d ........ 384....m
#06D2  65 74 61 44 61 74 61 64  00 00 00 0d 00 00 00 02 etaDatad ........
#06E2  73 00 00 00 0e 00 00 00  06 64 65 76 69 63 65 73 s....... .devices
#06F2  00 00 00 0f 00 00 00 06  69 50 68 6f 6e 65 73 00 ........ iPhones.
#0702  00 00 10 00 00 00 0d 63  6c 69 65 6e 74 56 65 72 .......c lientVer
#0712  73 69 6f 6e 73 00 00 00  11 00 00 00 05 32 2e 34 sions... .....2.4
#0722  2e 31 6e 69 00 00 00 00                          .1ni.... 


#mine (not working):		
#0319  2e 5b 56 54 56 5d 2e 6d  70 34 00 00 00 08 6d 65 .[VTV].m p4....me
#0329  74 61 44 61 74 61 64 00  00 00 0a 00 00 00 02 73 taDatad. .......s
#0339  00 00 00 0b 00 00 00 06  64 65 76 69 63 65 73 00 ........ devices.
#0349  00 00 0c 00 00 00 06 69  50 68 6f 6e 65 73 00 00 .......i Phones..
#0359  00 0d 00 00 00 0d 63 6c  69 65 6e 74 56 65 72 73 ......cl ientVers
#0369  69 6f 6e 73 00 00 00 0e  00 00 00 05 32 2e 34 2e ions.... ....2.4.
#0379  31 00 00 00 0f 72 65 73  6f 6c 75 74 69 6f 6e 57 1....	

	  case self.name	
	  when "metaData"
		"d#{[(@@to_avmap_counter += 1) - 1].pack("N")}#{[self.count].pack("N")}"+self.to_a.collect do |key,val|
			"s#{[(@@to_avmap_counter += 1) - 1].pack("N")}#{[key.length].pack("N")}#{key}"+val.to_avmap(false)
		end.join # need to add "ni"+"\000\000\000\000 = nil0"
		#(nil+0).to_avmap(true)
	  else
		"o#{[(@@to_avmap_counter += 1) - 1].pack("N")}#{[self.name.length].pack("N")}#{self.name}#{[version].pack("N")}#{[self.length].pack("N")}"+self.to_a.collect do |key,val|
			"#{[key.length].pack("N")}#{key}"+val.to_avmap(false)
		end.join	
	  end
	  
    when AirVideo::AvMap::BinaryData
      "x#{[(@@to_avmap_counter += 1) - 1].pack("N")}#{[self.length].pack("N")}#{self.data}"
    when String
	 # s:count:length:value
      "s#{[(@@to_avmap_counter += 1) - 1].pack("N")}#{[self.length].pack("N")}#{self}"
    #when Hash
	#  
    when NilClass
      "n"
    when Integer
	 # i:integer N = Long, network (big-endian) byte order
      "i#{[self].pack('N')}"
    when Float # unsure of this is what this is meant to be
      "f#{[self].pack('G')}"
    else
      raise NotImplementedError, "Can't turn a #{self.class} into an avmap"
    end
  end
end
