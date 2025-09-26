require 'csv'

require_relative "event_logger"
require_relative "qb_scraper_config"
require_relative "csv_queue"
require_relative "browser_session"
require_relative "proadvisor_parser"
require_relative "blocked_page_detector"
require_relative "scrape_progress_reporter"
require_relative "captcha_mitigation"

class QbScraper
  CSV_HEADERS = %w(accountant_name title_text emails social_sites proadvisor_link site error).freeze

  def initialize(input_source:)
    @user_agents = QbScraperConfig::USER_AGENTS
    @accept_language = QbScraperConfig::DEFAULT_ACCEPT_LANGUAGE
    @proxy_list = []
    @headless = true
    @timeout = 30
    @min_between = 30.0
    @max_between = 60.0
    @retries = 3
    @csv_queue = CsvQueue.new(
                   csv_filename: "proadvisor_results_incremental.csv",
                   input_source: input_source,
                   headers: CSV_HEADERS
                 )
    @progress_reporter = ScrapeProgressReporter.new
    @proxy_assignments = {}
  end

  def run
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    urls = @csv_queue.load_urls
    return if urls.empty?

    @progress_reporter.report_start(total_urls: urls.count)

    scrape_sequential(urls)

    @progress_reporter.report_completion(start_time: start_time)
  end

  private

  def scrape_sequential(urls)
    session_id = Thread.current.object_id
    session_helper = build_session(session_id: session_id)
    browser = session_helper.build

    begin
      urls.each_with_index do |url, idx|
        process_url(session_helper, browser, url, urls.size, idx)
      end
    ensure
      browser.quit if browser
    end
  end

  def process_url(session_helper, browser, url, total_urls, index)
    @progress_reporter.report_iteration_start(index: index, total: total_urls, url: url)

    start_time_row = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    retries_left = @retries

    while retries_left > 0
      html = session_helper.fetch_with_retries(browser, url)
      if html.nil?
        puts "Failed to fetch #{url}, skipping..."
        return
      end

      captcha_mitigation = CaptchaMitigation.new(blocked_page_detector: default_blocked_page_detector)

      mitigation_result = captcha_mitigation.handle(
        html: html,
        url: url,
        retries_left: retries_left,
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

      proadvisor = Struct.new(*CSV_HEADERS.map(&:to_sym))
      pro = ProadvisorParser.new(proadvisor).parse(html, url)
      @csv_queue.append(pro.to_a)
      @csv_queue.remove_source_url(url)

      @progress_reporter.report_success(index: index, total: total_urls, started_at: start_time_row)

      sleeping_for = rand(@min_between..@max_between)
      puts "Sleeping for #{sleeping_for} seconds"
      sleep(sleeping_for)
      return
    end
  end

  def build_session(session_id:)
    BrowserSession.new(
      headless: @headless,
      timeout: @timeout,
      accept_language: @accept_language,
      retries: @retries,
      proxy: select_proxy(session_id),
      user_agent: @user_agents.sample
    )
  end

  def select_proxy(session_id)
    return nil if @proxy_list.nil? || @proxy_list.empty?

    return @proxy_list.sample unless session_id

    @proxy_assignments[session_id] ||= @proxy_list.sample
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
