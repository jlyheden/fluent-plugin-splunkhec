require 'helper'
require 'webmock/test_unit'


class SplunkHECOutputTest < Test::Unit::TestCase
  HOST = 'splunk.example.com'
  PROTOCOL = 'https'
  PORT = '8443'
  TOKEN = 'BAB747F3-744E-41BA'
  SOURCE = 'fluentd'
  INDEX = 'main'
  EVENT_HOST = 'some_host'
  SOURCETYPE = 'log'

  SPLUNK_URL = "#{PROTOCOL}://#{HOST}:#{PORT}/services/collector/event"

  ### for Splunk HEC
  CONFIG = %[
    host #{HOST}
    protocol #{PROTOCOL}
    port #{PORT}
    token #{TOKEN}
    source #{SOURCE}
    index #{INDEX}
    event_host #{EVENT_HOST}
  ]

  def create_driver_splunkhec(conf = CONFIG)
    Fluent::Test::BufferedOutputTestDriver.new(Fluent::SplunkHECOutput).configure(conf)
  end

  def setup
    Fluent::Test.setup
    require 'fluent/plugin/out_splunkhec'
    stub_request(:any, SPLUNK_URL)
  end

  def test_should_require_mandatory_parameter_token
    assert_raise Fluent::ConfigError do
      create_driver_splunkhec(%[])
    end
  end

  def test_should_use_default_values_for_optional_parameters
    d = create_driver_splunkhec(%[token some_token])
    assert_equal 'localhost', d.instance.host
    assert_equal 'http', d.instance.protocol
    assert_equal '8088', d.instance.port
    assert_equal 'main', d.instance.index
    assert_equal `hostname`.delete!("\n"), d.instance.event_host
    assert_equal 'fluentd', d.instance.source
    assert_equal 'tag', d.instance.sourcetype
    assert_equal false, d.instance.send_event_as_json
    assert_equal true, d.instance.usejson
    assert_equal false, d.instance.send_batched_events
    assert_equal 'some_token', d.instance.token
  end

  def test_should_configure_splunkhec
    d = create_driver_splunkhec
    assert_equal HOST, d.instance.host
    assert_equal PROTOCOL, d.instance.protocol
    assert_equal PORT, d.instance.port
    assert_equal TOKEN, d.instance.token
  end

  def test_should_post_formatted_event_to_splunk
    sourcetype = 'log'
    time = 123456
    record = {'message' => 'data'}

    splunk_request = stub_request(:post, SPLUNK_URL)
                         .with(
                             headers: {
                                 'Authorization' => "Splunk #{TOKEN}",
                                 'Content-Type' => 'application/json; charset=utf-8'
                             },
                             body: {
                                 'time' => time,
                                 'event' => record.to_json,
                                 'sourcetype' => sourcetype,
                                 'source' => SOURCE,
                                 'index' => INDEX,
                                 'host' => EVENT_HOST
                             })

    d = create_driver_splunkhec(CONFIG + %[sourcetype #{sourcetype}])
    d.run do
      d.emit(record, time)
    end

    assert_requested(splunk_request)
  end

  def test_should_use_tag_as_sourcetype_when_configured
    splunk_request = stub_request(:post, SPLUNK_URL).with(body: hash_including({'sourcetype' => 'test'}))

    d = create_driver_splunkhec(CONFIG + %[sourcetype tag])
    d.run do
      d.emit({'message' => 'data'}, 123456)
    end

    assert_requested(splunk_request)
  end

  def test_should_send_event_as_string_as_default
    record = {'message' => 'data'}
    splunk_request = stub_request(:post, SPLUNK_URL).with(body: hash_including({'event' => record.to_json}))

    d = create_driver_splunkhec(CONFIG + %[send_event_as_json false])
    d.run do
      d.emit(record)
    end

    assert_requested(splunk_request)
  end

  def test_should_send_event_as_log4j_format_when_configured
    log_time = '2017-07-02 20:52:39'
    log_time_millis = '1499028759000'
    log_event = 'data'

    splunk_request = stub_request(:post, SPLUNK_URL)
                         .with(body: hash_including({'time' => log_time_millis, 'event' => "#{log_time} #{log_event}"}))

    d = create_driver_splunkhec(CONFIG + %[usejson false])
    d.run do
      d.emit({'time' => log_time, 'message' => log_event})
    end

    assert_requested(splunk_request)
  end

  def test_should_send_event_as_json_when_configured
    record = {'message' => 'data'}

    splunk_request = stub_request(:post, SPLUNK_URL).with(body: hash_including({'event' => record}))

    d = create_driver_splunkhec(CONFIG + %[send_event_as_json true])
    d.run do
      d.emit(record)
    end

    assert_requested(splunk_request)
  end

  def test_should_batch_post_all_events_in_chunk_when_configured
    record1 = {'message' => 'data'}
    record2 = {'message' => 'more data'}

    splunk_request = stub_request(:post, SPLUNK_URL).with(body: /\"event\" :#{record1.to_json}.*\"event\" :#{record2.to_json}/m)

    d = create_driver_splunkhec(CONFIG + %[
      send_event_as_json true
      send_batched_events true])

    d.run do
      d.emit(record1)
      d.emit(record2)
    end

    assert_requested(splunk_request)
  end

  def test_should_raise_exception_when_splunk_returns_error_to_make_fluentd_retry_later
    stub_request(:any, SPLUNK_URL).to_return(status: 403, body: {'text' => 'Token disabled', 'code' => 1}.to_json)

    assert_raise Fluent::SplunkHECOutputError do
      d = create_driver_splunkhec
      d.run do
        d.emit({'message' => 'data'})
      end
    end
  end

  def test_should_handle_ascii_8bit_encoded_message_with_utf8_chars_correctly
    record = {'message' => "\xC2\xA92017".b}

    splunk_request = stub_request(:post, SPLUNK_URL).with(body: hash_including({'event' => {'message' => '©2017'}}))

    d = create_driver_splunkhec(CONFIG + %[send_event_as_json true])
    d.run do
      d.emit(record)
    end

    assert_requested(splunk_request)
  end

  def test_should_use_dynamic_index
    splunk_request = stub_request(:post, SPLUNK_URL).with(body: hash_including({'index' => 'prefix_fluentd_mypod'}))

    cfg = CONFIG + %[
      dynamic_index true
      dynamic_index_pattern prefix_${source}_${record['kubernetes']['pod_name']}
    ]

    d = create_driver_splunkhec(cfg)
    d.run do
      d.emit(
        {
          'message' => 'data',
          'kubernetes' => {
            'pod_name' => 'mypod'
          }
        }
      )
    end
    assert_requested(splunk_request)
  end

end
