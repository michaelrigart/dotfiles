require 'irb/completion'
require 'irb/ext/save-history'

IRB.conf[:SAVE_HISTORY] = 1000
IRB.conf[:HISTORY_FILE] = "#{ENV['XDG_CACHE_HOME']}/irb/irb_history"
IRB.conf[:AUTO_INDENT]  = true
IRB.conf[:PROMPT_MODE] = :SIMPLE

begin
  require 'pry'
  Pry.start
  exit
rescue LoadError => e
  warn '=> Unable to load pry'
end
