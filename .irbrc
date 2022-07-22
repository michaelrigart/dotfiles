#require 'irb/completion'
require 'irb/ext/save-history'

IRB.conf[:SAVE_HISTORY] = 1000
IRB.conf[:HISTORY_FILE] = "#{ENV['XDG_CACHE_HOME']}/irb/irb_history"
IRB.conf[:AUTO_INDENT]  = true
IRB.conf[:PROMPT_MODE]  = :SIMPLE
IRB.conf[:USE_AUTOCOMPLETE] = true
IRB.conf[:USE_COLORIZE] = false

if defined?(Rails)
  app = Rails.application.class.name.split('::').first
  env_color = if Rails.env.production?
                "\e[31m#{Rails.env}\e[0m"
              else
                "\e[32m#{Rails.env}\e[0m"
              end


  IRB.conf[:PROMPT] ||= {}
  IRB.conf[:PROMPT][:RAILS] = {
    AUTO_INDENT: true,
    PROMPT_I: "#{app} (#{env_color}) %03n:%i >> ",
    PROMPT_N: "#{app} (#{env_color}) %03n:%i >> ",
    PROMPT_S: "#{app} (#{env_color}) %03n:%i >> ",
    PROMPT_C: "#{app} (#{env_color}) %03n:%i >> ",
    RETURN:   "==> %s\n"
  }

  IRB.conf[:PROMPT_MODE] = :RAILS
end
