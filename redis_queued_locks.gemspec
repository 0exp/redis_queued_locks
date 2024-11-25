# frozen_string_literal: true

require_relative 'lib/redis_queued_locks/version'

Gem::Specification.new do |spec|
  spec.required_ruby_version = '>= 3.1'

  spec.name = 'redis_queued_locks'
  spec.version = RedisQueuedLocks::VERSION
  spec.authors = ['Rustam Ibragimov']
  spec.email = ['iamdaiver@gmail.com']

  spec.summary =
    'Distributed locks with "prioritized lock acquisition queue" ' \
    'capabilities based on the Redis Database.'

  spec.description =
    "|> Distributed locks with \"prioritized lock acquisition queue\" capabilities " \
    "based on the Redis Database.\n" \
    "|> Each lock request is put into the request queue " \
    "(each lock is hosted by it's own queue separately from other queues) and processed " \
    "in order of their priority (FIFO).\n" \
    "|> Each lock request lives some period of time (RTTL) " \
    "(with requeue capabilities) which guarantees the request queue will never be stacked.\n" \
    "|> In addition to the classic `queued` (FIFO) strategy RQL supports " \
    "`random` (RANDOM) lock obtaining strategy when any acquirer from the lock queue " \
    "can obtain the lock regardless the position in the queue.\n" \
    "|> Provides flexible invocation flow, parametrized limits " \
    "(lock request ttl, lock ttl, queue ttl, lock attempts limit, fast failing, etc), " \
    "logging and instrumentation."

  spec.homepage = 'https://github.com/0exp/redis_queued_locks'
  spec.license = 'MIT'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/blob/master"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end

  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'redis-client', '~> 0.20'
  spec.add_dependency 'qonfig', '~> 0.28'

  # NOTE:
  #   - steep depends on "activesupport";
  #   - but "activesupport" requires "ruby >= 3.2";
  #   - and RQL supports "ruby >= 3.1";
  #   - so we need to downgrade "activesupport" dependency manually;
  spec.add_development_dependency 'activesupport', '< 8'

  spec.add_development_dependency 'armitage-rubocop'
  spec.add_development_dependency 'bundler'
  spec.add_development_dependency 'pry'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rbs'
  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'steep'
end
