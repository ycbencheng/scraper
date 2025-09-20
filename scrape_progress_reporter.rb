class ScrapeProgressReporter
  def initialize(event_logger: EventLogger, output: $stdout, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @event_logger = event_logger
    @output = output
    @clock = clock
  end

  def report_start(total_urls:)
    return if total_urls.zero?

    @output.puts "--- Total of #{total_urls} ProAdvisor URLs to scrape ---"
  end

  def report_iteration_start(index:, total:, url:)
    @event_logger.log(:outgoing, "Starting #{index + 1}/#{total}, Url: #{url}")
  end

  def report_success(index:, total:, started_at:)
    elapsed = @clock.call - started_at
    @event_logger.log(:success, "Saved! Time taken: #{elapsed.round(2)}s (#{index + 1}/#{total})")
  end

  def report_completion(start_time:)
    elapsed = @clock.call - start_time
    @output.puts "Done. Total time - #{elapsed.round(2)} seconds"
  end
end