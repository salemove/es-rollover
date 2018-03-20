# frozen_string_literal: true

require 'es_rollover'
require_relative 'es_context'

RSpec.describe ESRollover, '#roll_indices_over' do
  include_context 'with Elasticsearch'

  it 'rolls over indices older than max_age' do
    index_prefix = "test-#{test_identifier}-log"
    initial_index_name = "#{index_prefix}-000001"
    rolled_over_index_name = "#{index_prefix}-000002"

    create_index(index: initial_index_name)
    create_alias(to: initial_index_name, name: index_prefix)
    es_rollover(max_age: '1nanos').roll_indices_over

    expect(es).to have_index(initial_index_name)
    expect(es).to have_index(rolled_over_index_name)
  end

  it 'directs new writes to the new index created after rollover' do
    index_prefix = "test-#{test_identifier}-log"
    initial_index_name = "#{index_prefix}-000001"
    rolled_over_index_name = "#{index_prefix}-000002"
    message = 'Test log'

    create_index(index: initial_index_name)
    create_alias(to: initial_index_name, name: index_prefix)
    es_rollover(max_age: '1nanos').roll_indices_over
    post_event(index: index_prefix, message: message)
    refresh(index: rolled_over_index_name)

    expect(rolled_over_index_name).to have_event(message: message)
  end

  it 'does not roll over indices younger than max_age' do
    index_prefix = "test-#{test_identifier}-log"
    initial_index_name = "#{index_prefix}-000001"
    rolled_over_index_name = "#{index_prefix}-000002"

    create_index(index: initial_index_name)
    create_alias(to: initial_index_name, name: index_prefix)
    es_rollover(max_age: '1d').roll_indices_over

    expect(es).to have_index(initial_index_name)
    expect(es).not_to have_index(rolled_over_index_name)
  end

  it 'rolls over indices larger than max_size' do
    index_prefix = "test-#{test_identifier}-log"
    initial_index_name = "#{index_prefix}-000001"
    rolled_over_index_name = "#{index_prefix}-000002"

    post_event(index: initial_index_name, message: 'More than 1b of text')
    refresh(index: initial_index_name)
    create_alias(to: initial_index_name, name: index_prefix)
    es_rollover(max_size: '1b').roll_indices_over

    expect(es).to have_index(initial_index_name)
    expect(es).to have_index(rolled_over_index_name)
  end

  it 'does not roll over indices smaller than max_size' do
    index_prefix = "test-#{test_identifier}-log"
    initial_index_name = "#{index_prefix}-000001"
    rolled_over_index_name = "#{index_prefix}-000002"

    post_event(index: initial_index_name, message: 'Less than 1gb of text')
    refresh(index: initial_index_name)
    create_alias(to: initial_index_name, name: index_prefix)
    es_rollover(max_size: '1gb').roll_indices_over

    expect(es).to have_index(initial_index_name)
    expect(es).not_to have_index(rolled_over_index_name)
  end
end
