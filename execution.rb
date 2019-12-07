require 'dotenv/load'
require './telechannel'

telechannel = Telechannel.new(ENV['TELECHANNEL_TOKEN'])
telechannel.run
