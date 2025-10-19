# frozen_string_literal: true

# @api public
# @since ?.?.?
module RedisQueuedLocks::Stats
  # 1. инструментер, который сабскрайбится на события локов
  # 2. редис-ключики, которые каюнтят стату с per-period-значением
end

__END__

Stats::History.configure do |config|
  config.period_type = :second / :minute / :hour / :day / :week
  config.stored_stats_period_range = 1.day / 2.days / etc
end

Stats.cleanup
Stats.processed_lock_count # <--- overall
Stats.active_lock_count
Stats.waiting_lock_count
Stats.lock_queues
Stats.active_locks

Stats::History.lock_count # <-- every time period
Stats::History.active_lock_count
Stats::History.waiting_lock_count
Stats::History.cleanup


require 'webrick'

server = WEBrick::HTTPServer.new(
  Port: 8080,
  DocumentRoot: './public',
)

trap('INT') { server.shutdown }
server.start

__END__

35 x 109 x 53
