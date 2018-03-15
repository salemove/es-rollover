# frozen_string_literal: true

require 'faraday'
require 'faraday_middleware'
require 'logasm'

# The index pattern used by both uninitialized indices and by aliases pointing
# to already initialized indices.
ES_INDEX_PATTERN = '*-*-log'
REGEX_INDEX_PATTERN = /^.*-.*-log$/

$log_level = ENV.fetch('LOG_LEVEL', 'info')
$log_json = ENV.fetch('LOG_JSON', 'false') == 'true'
$host = ENV.fetch('ELASTICSEARCH_URL', 'http://localhost:9200')
$max_age = ENV.fetch('MAX_AGE', '7d')
$max_docs = Integer(ENV.fetch('MAX_DOCS', '400000000'), 10) # 400m

# During slow operations, such as reindexing, the logs may not be flushed for
# a while, while they're buffered for STDOUT. Setting STDOUT to sync mode
# avoids buffering, so it's easier to gauge progress.
$stdout.sync = true
$logger = Logasm.build('es-rollover', stdout: {level: $log_level, json: $log_json})
$es = Faraday.new($host) do |conn|
  conn.request(:json)
  conn.response(:json, content_type: /\bjson$/)
  conn.use(Faraday::Response::RaiseError)
  conn.adapter(Faraday.default_adapter)
end

def format_error(error)
  base_context = {
    error: {
      message: error.message,
      backtrace: error.backtrace.join("\n")
    }
  }

  if error.is_a?(Faraday::ClientError) && error.response
    base_context.merge(status: error.response.fetch(:status))
  else
    base_context
  end
end

def run
  uninitialized_indices = fetch_uninitialized_indices
  uninitialized_indices.each.with_index do |index_name, i|
    initialize_rollover_for_index(index_name)
    $logger.info(
      'Finished initializing rollover for index',
      index: index_name,
      total_indices: uninitialized_indices.length,
      indices_finished: i + 1,
      indices_left: uninitialized_indices.length - (i + 1)
    )
  rescue StandardError => e
    $logger.error(
      'Failed to initialize rollover for index. Continuing with the rest.',
      format_error(e).merge(index: index_name)
    )
  end

  rollover_aliases = fetch_rollover_aliases
  rollover_aliases.each.with_index do |alias_name, i|
    rollover(alias_name)
    $logger.info(
      'Finished rollover for alias',
      alias: alias_name,
      total_aliases: rollover_aliases.length,
      aliases_finished: i + 1,
      aliases_left: rollover_aliases.length - (i + 1)
    )
  rescue StandardError => e
    $logger.error(
      'Failed to rollover alias. Continuing with the rest.',
      format_error(e).merge(alias: alias_name)
    )
  end
end

def fetch_uninitialized_indices
  $es.get(ES_INDEX_PATTERN)
    .body
    .select { |index_name, _index| index_name.match?(REGEX_INDEX_PATTERN) }
    .keys
end

def disable_writes(index_name)
  $logger.info('Disabling writes for index', index: index_name)
  $es.put("#{index_name}/_settings", 'index.blocks.write': true)
end

def create_name_with_counter_suffix(index_name)
  "#{index_name}-000001"
end

REINDEX_RESULT_CONTEXT = %w[timed_out total created updated took].freeze
def reindex(from:, to:) # rubocop:disable Naming/UncommunicativeMethodParamName
  $logger.info('Reindexing data from index to rename with suffix', from: from, to: to)
  response = $es.post(
    '_reindex?wait_for_active_shards=all&requests_per_second=500&timeout=1h',
    source: {index: from},
    dest: {index: to}
  ) do |req|
    req.options.timeout = 60 * 60 # an hour in seconds
  end

  log_context = response.body.slice(*REINDEX_RESULT_CONTEXT).merge(from: from, to: to)
  $logger.info('Reindexing result', log_context)

  return if response.body.fetch('total') >= 1
  $logger.info('Reindex did not create a new index, creating empty index', from: from, to: to)
  $es.put(to)
end

def replace_index_with_alias(index:, alias_to:)
  $logger.info('Deleting index and replacing with alias', index: index, alias_to: alias_to)
  $es.post('_aliases', actions: [
    {add: {index: alias_to, alias: index}},
    {remove_index: {index: index}}
  ])
end

def initialize_rollover_for_index(index_name)
  $logger.info('Starting rollover initialization', index: index_name)
  disable_writes(index_name)
  new_index_name = create_name_with_counter_suffix(index_name)
  reindex(from: index_name, to: new_index_name)
  replace_index_with_alias(index: index_name, alias_to: new_index_name)
end

def fetch_rollover_aliases
  $es.get("_alias/#{ES_INDEX_PATTERN}")
    .body
    .values
    .map do |index|
      all_aliases = index.fetch('aliases').keys
      matching_aliases = all_aliases.select { |alias_name| alias_name.match?(REGEX_INDEX_PATTERN) }
      if matching_aliases.count != 1
        $logger.error(
          'Expected exactly one matching alias',
          all_aliases: all_aliases,
          matching_aliases: matching_aliases
        )
        raise 'Expected exactly one matching alias'
      end
      matching_aliases.first
    end
rescue Faraday::ResourceNotFound => e
  $logger.warn('Elasticsearch returned 404 for rollover_aliases request', format_error(e))
  []
end

ROLLOVER_RESULT_CONTEXT = %w[old_index new_index rolled_over acknowledged].freeze
def rollover(alias_name)
  $logger.info('Executing rollover for alias', alias: alias_name)
  response = $es.post("#{alias_name}/_rollover", conditions: {
    max_age: $max_age,
    max_docs: $max_docs
  })

  log_context = response.body.slice(*ROLLOVER_RESULT_CONTEXT).merge(alias: alias_name)
  if response.body.fetch('rolled_over')
    $logger.info('Successfully rolled over alias to new index', log_context)
  else
    $logger.info('Skipped rolling over an alias', log_context)
  end
end

run
