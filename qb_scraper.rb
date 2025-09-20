require 'csv'

require_relative "event_logger"
require_relative "qb_scraper_config"
require_relative "csv_queue"
require_relative "browser_session"
require_relative "proadvisor_parser"
require_relative "blocked_page_detector"
require_relative "scrape_progress_reporter"
require_relative "browser_session_profile"
require_relative "captcha_mitigation"

class QbScraper
  CSV_HEADERS = %w(accountant_name title_text emails social_sites proadvisor_link site error).freeze

  def initialize(input_source: nil, options: {})
    @user_agents = options.fetch(:user_agents, QbScraperConfig::USER_AGENTS)
    @accept_language = options.fetch(:accept_language, QbScraperConfig::DEFAULT_ACCEPT_LANGUAGE)
    @proxy_list = options.fetch(:proxy_list, []) # strings like "host:port" or "http://user:pass@host:port"
    @headless = options.fetch(:headless, true)
    @timeout = options.fetch(:timeout, 30)
    @min_between = options.fetch(:min_between, 8.0)
    @max_between = options.fetch(:max_between, 10.0)
    @retries = options.fetch(:retries, 3)
    csv_filename = options.fetch(:csv_filename, "proadvisor_results_incremental.csv")
    @csv_queue = options.fetch(:csv_queue, nil) ||
                 CsvQueue.new(
                   csv_filename: csv_filename,
                   input_source: input_source,
                   headers: CSV_HEADERS
                 )
    proadvisor = Struct.new(:accountant_name, :title_text, :emails, :social_sites, :proadvisor_link, :site, :error)
    @parser = options.fetch(:proadvisor_parser, ProadvisorParser.new(proadvisor))
    @blocked_page_detector = options.fetch(:blocked_page_detector, default_blocked_page_detector)
    @progress_reporter = options.fetch(:progress_reporter, ScrapeProgressReporter.new)
    @session_profile = options.fetch(
      :session_profile,
      BrowserSessionProfile.new(
        headless: @headless,
        timeout: @timeout,
        accept_language: @accept_language,
        retries: @retries,
        proxy_list: @proxy_list,
        user_agents: @user_agents
      )
    )
    @captcha_mitigation = options.fetch(
      :captcha_mitigation,
      CaptchaMitigation.new(blocked_page_detector: @blocked_page_detector)
    )
  end

  def run(direct_urls = [])
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    urls = @csv_queue.load_urls(direct_urls)
    return if urls.empty?

    @progress_reporter.report_start(total_urls: urls.count)

    scrape_sequential(urls)

    @progress_reporter.report_completion(start_time: start_time)
  end

  private

  def scrape_sequential(urls)
    session_id = Thread.current.object_id
    session_helper = @session_profile.build_session(session_id: session_id)
    browser = session_helper.build

    begin
      urls.each_with_index do |url, idx|
        process_url(session_helper, browser, url, idx, urls.size)
      end
    ensure
      browser.quit if browser
    end
  end

  def process_url(session_helper, browser, url, index, total_urls)
    @progress_reporter.report_iteration_start(index: index, total: total_urls, url: url)

    start_time_row = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    retries_left = @retries

    while retries_left > 0
      html = session_helper.fetch_with_retries(browser, url)
      if html.nil?
        puts "Failed to fetch #{url}, skipping..."
        return
      end

      mitigation_result = @captcha_mitigation.handle(
        html: html,
        url: url,
        retries_left: retries_left,
        browser: browser,
        total_retries: @retries
      )

      case mitigation_result[:status]
      when :retry
        retries_left = mitigation_result[:retries_left]
        next
      when :abort
        browser.quit if browser
        exit 1
      end

      pro = @parser.parse(html, url)
      @csv_queue.append(pro.to_a)
      @csv_queue.remove_source_url(url)

      @progress_reporter.report_success(index: index, total: total_urls, started_at: start_time_row)

      sleep(rand(@min_between..@max_between))
      return
    end
  end

  def default_blocked_page_detector
    BlockedPageDetector.new(
      event_logger: ->(url:, **) { EventLogger.log(:blocked, "⚠️ CAPTCHA/security page detected on #{url}") if url },
      csv_logger: ->(url:, **) do
        next unless url

        CSV.open("blocked_urls.csv", "ab") { |csv| csv << [url] }
      end
    )
  end
end

# CLI
if __FILE__ == $0
  require_relative "qb_scraper_cli"
  
  QbScraperCLI.new(ARGV).run
end
