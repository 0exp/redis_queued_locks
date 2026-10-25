# frozen_string_literal: true

require 'etc'
require 'fileutils'
require 'json'
require 'redis_client'

# NOTE: (parallel specs) the runner of `rake rspec:parallel` (`Rakefile`): the specs in several
#   processes (workers) with one local Redis:
#   - each worker gets its own pair of Redis databases (the specs use db 0 and db 1):
#     `RQL_SPEC_DB_OFFSET` = worker index * 2 (see `spec/spec_helper.rb`), so the workers never
#     flush or scan the keys of each other (the `databases` of the Redis config limit the workers);
#   - the examples are listed by `rspec --dry-run` and distributed by their durations of the
#     previous runs (`tmp/rspec_parallel/durations.json`, `durations-rbs.json` for the RBS runtime
#     checks: some examples are much slower there): the longest example first, each to the least
#     loaded worker (examples without a recorded duration count as the median one);
#   - each worker writes its output to `tmp/rspec_parallel/worker-<n>.log`; the task prints the
#     summary, the failures with the rerun command, and fails when any worker fails;
#   - coverage: each worker stores its result in `coverage/parallel/worker-<n>` (see
#     `spec/spec_helper.rb`), the task collates the report of the whole run into `coverage/` once
#     all workers are finished (`SimpleCov.collate`: no report is built from partial results);
#   - the environment is passed to the workers as is (`RSPEC_RETRY_RETRY_COUNT`, the RBS runtime
#     checks, ...);
# rubocop:disable Metrics/ModuleLength
module RQLParallelSpecs
  DIR = 'tmp/rspec_parallel'
  DURATIONS_PATH =
    File.join(DIR, ENV.key?('RBS_TEST_TARGET') ? 'durations-rbs.json' : 'durations.json')
  LISTING_PATH = File.join(DIR, 'examples.json')
  # NOTE: the Redis databases of the specs: db 0 and db 1 (`all in + notifications`)
  DATABASES_PER_WORKER = 2

  module_function

  def run(workers, rspec_args)
    # NOTE: the progress lines are shown as they happen when the output is a pipe (CI logs)
    $stdout.sync = true
    FileUtils.mkdir_p(DIR)
    max_workers = redis_databases / DATABASES_PER_WORKER
    workers ||= [max_workers, Etc.nprocessors].min
    unless workers.between?(1, max_workers)
      abort("WORKERS should be from 1 to #{max_workers} (the Redis databases).")
    end

    examples = list_examples(rspec_args)
    abort('No examples found.') if examples.empty?
    groups = distribute(examples, load_durations, workers)
    # NOTE: the coverage results of the previous parallel run
    FileUtils.rm_rf('coverage/parallel')
    started_at = clock
    statuses = run_workers(groups, examples.size, started_at)
    collate_coverage
    report(statuses, clock - started_at)
  end

  def collate_coverage
    resultsets = Dir['coverage/parallel/worker-*/.resultset.json']
    return if resultsets.empty?

    require 'simplecov'
    require_relative '../setup_simplecov'
    SimpleCov.collate(resultsets)
    # NOTE: the collated results are not merged into the reports of the next runs (`rspec` runs
    #   within the SimpleCov `merge_timeout` would report the union with this run)
    FileUtils.rm_f('coverage/.resultset.json')
  end

  def redis_databases
    redis = RedisClient.config.new_client
    reply = redis.call('CONFIG', 'GET', 'databases')
    Integer(reply.is_a?(Hash) ? reply['databases'] : reply.last)
  rescue StandardError
    16 # NOTE: the Redis default (`CONFIG` can be disabled)
  ensure
    redis&.close
  end

  def list_examples(rspec_args)
    listed = system(
      { 'RQL_SPEC_LISTING' => '1' }, 'bundle', 'exec', 'rspec', '--dry-run',
      '--format', 'json', '--out', LISTING_PATH, *rspec_args, out: File::NULL
    )
    abort('Failed to list the examples (rspec --dry-run).') unless listed
    JSON.parse(File.read(LISTING_PATH)).fetch('examples').map { |example| example.fetch('id') }
  end

  def load_durations
    File.exist?(DURATIONS_PATH) ? JSON.parse(File.read(DURATIONS_PATH)) : {}
  end

  # NOTE: the example ids of each worker and their estimated duration
  def distribute(examples, durations, workers)
    known = durations.values_at(*examples).compact.sort
    default = known.empty? ? 1.0 : known[known.size / 2]
    groups = Array.new([workers, examples.size].min) { [[], 0.0] }
    examples.sort_by { |id| -durations.fetch(id, default) }.each do |id|
      group = groups.min_by(&:last)
      group[0] << id
      group[1] += durations.fetch(id, default)
    end
    groups
  end

  def run_workers(groups, examples_count, started_at)
    puts "Running #{examples_count} examples in #{groups.size} workers " \
         "(logs: #{DIR}/worker-<n>.log)"
    pids = groups.each_with_index.to_h do |(ids, estimate), index|
      puts "  worker #{index + 1}: #{ids.size} examples (~#{format_time(estimate)})"
      [spawn_worker(index, ids), index]
    end
    pids.size.times.to_h do
      pid, status = Process.wait2
      index = pids.fetch(pid)
      summary = worker_result(index)&.fetch('summary_line', nil) || 'no results (see the log)'
      puts "  worker #{index + 1} finished in #{format_time(clock - started_at)}: #{summary}"
      [index, status]
    end
  end

  def spawn_worker(index, ids)
    env = {
      'RQL_SPEC_WORKER' => (index + 1).to_s,
      'RQL_SPEC_DB_OFFSET' => (index * DATABASES_PER_WORKER).to_s
    }
    Process.spawn(
      env, 'bundle', 'exec', 'rspec', '--format', 'progress',
      '--format', 'json', '--out', worker_file(index, 'json'), *ids,
      out: worker_file(index, 'log'), err: %i[child out]
    )
  end

  def worker_file(index, extension)
    File.join(DIR, "worker-#{index + 1}.#{extension}")
  end

  def worker_result(index)
    path = worker_file(index, 'json')
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
  rescue JSON::ParserError
    nil
  end

  def report(statuses, wall_time)
    indexes = statuses.keys.sort
    examples = indexes.filter_map { |index| worker_result(index) }
                      .flat_map { |result| result.fetch('examples') }
    failed = examples.select { |example| example['status'] == 'failed' }
    broken = indexes.select { |index| worker_result(index) == nil }
    save_durations(examples)

    puts
    indexes.each { |index| puts File.readlines(worker_file(index, 'log')).grep(/RSpec::Retry: /) }
    failed.each_with_index { |example, number| report_failure(example, number) }
    broken.each { |index| report_broken_worker(index, statuses.fetch(index)) }
    puts
    puts "#{examples.size} example(s), #{failed.size} failure(s) in #{format_time(wall_time)} " \
         "(#{statuses.size} worker(s))"
    if failed.any?
      puts "Rerun the failures: bundle exec rspec #{failed.map { |e| e['id'] }.join(' ')}"
    end
    abort('Parallel specs failed.') unless failed.empty? && statuses.values.all?(&:success?)
  end

  def report_failure(example, number)
    puts
    puts "#{number + 1}) #{example['full_description']}"
    puts "   #{example['file_path']}:#{example['line_number']} (#{example['id']})"
    puts "   #{example.dig('exception', 'message').to_s.strip.lines.first(10).join('   ')}"
  end

  def report_broken_worker(index, status)
    puts
    puts "worker #{index + 1}: no results (exit #{status.exitstatus}), the log tail:"
    puts File.readlines(worker_file(index, 'log')).last(20).join
  end

  def save_durations(examples)
    durations = load_durations
    examples.each { |example| durations[example['id']] = example['run_time'] }
    File.write(DURATIONS_PATH, JSON.pretty_generate(durations))
  end

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def format_time(seconds)
    format('%<min>d:%<sec>02d', min: seconds / 60, sec: seconds % 60)
  end
end
# rubocop:enable Metrics/ModuleLength
