# frozen_string_literal: true

require 'dotenv/load' if ENV['RACK_ENV'] != 'production'
require 'redis'

require_relative 'app/webhook_app'
require_relative 'lib/missive/delivery_log'

redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/0'))

Missive::WebhookApp.set :signature_secret, ENV.fetch('MISSIVE_SIGNATURE_SECRET')
Missive::WebhookApp.set :delivery_log, Missive::DeliveryLog.new(redis)

run Missive::WebhookApp
