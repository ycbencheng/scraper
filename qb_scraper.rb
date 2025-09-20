require "nokogiri"
require 'csv'
require 'launchy'
require "uri"
require 'byebug'

require_relative "event_logger"
require_relative "qb_scraper_config"
require_relative "csv_queue"
require_relative "browser_session"
require_relative "proadvisor_parser"

class QbScraper
  CSV_HEADERS = %w(accountant_name title_text emails social_sites proadvisor_link site error).freeze

  def initialize(input_source: nil, options: {})
    @input_source = input_source
    @user_agents = options.fetch(:user_agents, QbScraperConfig::USER_AGENTS)
    @accept_language = options.fetch(:accept_language, QbScraperConfig::DEFAULT_ACCEPT_LANGUAGE)
    @proxy_list = options.fetch(:proxy_list, []) # strings like "host:port" or "http://user:pass@host:port"
    @headless = options.fetch(:headless, true)
    @timeout = options.fetch(:timeout, 30)
    @min_between = options.fetch(:min_between, 8.0)
    @max_between = options.fetch(:max_between, 10.0)
    @retries = options.fetch(:retries, 3)
    @csv_filename = options.fetch(:csv_filename, "proadvisor_results_incremental.csv")
    @proadvisor = Struct.new(:accountant_name, :title_text, :emails, :social_sites, :proadvisor_link, :site, :error)
    @csv_queue = options.fetch(:csv_queue, nil) ||
                 CsvQueue.new(
                   csv_filename: @csv_filename,
                   input_source: @input_source,
                   headers: CSV_HEADERS
                 )
    @parser = options.fetch(:proadvisor_parser, ProadvisorParser.new(@proadvisor))
  end

  def run(direct_urls = [])
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    urls = @csv_queue.load_urls(direct_urls)
    return if urls.empty?

    puts "--- Total of #{urls.count} ProAdvisor URLs to scrape ---"

    scrape_sequential(urls)

    total_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
    puts "Done. Total time - #{total_elapsed.round(2)} seconds"
  end

  private

  def scrape_sequential(urls)
    total_urls = urls.size
    session_helper = BrowserSession.new(
      headless: @headless,
      timeout: @timeout,
      accept_language: @accept_language,
      retries: @retries,
      proxy: pick_proxy_for_request(nil),
      user_agent: pick_user_agent
    )
    browser = session_helper.build

    begin
      urls.each_with_index do |url, idx|
        process_url(session_helper, browser, url, idx, total_urls)
      end
    ensure
      browser.quit if browser
    end
  end

  def fetch_with_retries(browser, url, max_attempts = @retries + 1)
    attempt_number = 0

    begin
      attempt_number += 1
      browser.goto(url)
      browser.network.wait_for_idle(duration: rand(5.0..7.0))
      simulate_reading_pause(browser)

      browser.body

    rescue => e
      puts "[Error] #{e}"
      attempts_left = max_attempts - attempt_number
      if attempts_left > 0
        puts "[Retry] Retrying #{url} (attempt #{attempt_number + 1}/#{max_attempts})"
        sleep(rand(3..6))
        retry
      else
        puts "[Failed] Could not fetch #{url} after #{attempt_number} attempts"
        nil
      end
    end
  end

  def process_url(session_helper, browser, url, index, total_urls)
    EventLogger.log(:outgoing, "Starting #{index + 1}/#{total_urls}, Url: #{url}")
    start_time_row = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    retries_left = @retries

    while retries_left > 0
      html = session_helper.fetch_with_retries(browser, url)
      if html.nil?
        puts "Failed to fetch #{url}, skipping..."
        return
      end

      if blocked_page?(html, url)
        puts "Blocked detected. Open browser and solve CAPTCHA (waiting 30s)..."
        Launchy.open(url)
        sleep(30)

        retries_left -= 1
        if retries_left <= 0
          puts "🚨 #{url} blocked #{@retries} times. Exiting scraper gracefully."
          browser.quit if browser
          exit 1
        else
          next
        end
      end

      pro = @parser.parse(html, url)
      @csv_queue.append(pro.to_a)
      @csv_queue.remove_source_url(url)

      end_time_row = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = end_time_row - start_time_row
      EventLogger.log(:success, "Saved! Time taken: #{elapsed.round(2)}s (#{index + 1}/#{total_urls})")

      sleep(rand(@min_between..@max_between))
      return
    end
  end

  def blocked_page?(html, url)
    return false if html.nil? || html.strip.empty?

    body = Nokogiri::HTML(html)

    blocked_selectors = [
      '#qba-matchmaking-ui-search-captcha',
      'h2.captcha-title',
      '.g-recaptcha',
      "form[action*='captcha']"
    ]
    blocked_regex = /captcha|verify you are human|unusual traffic|security verification/i

    is_blocked = blocked_regex.match?(body.text) ||
                 blocked_selectors.any? { |sel| !body.css(sel).empty? }

    if is_blocked
      EventLogger.log(:blocked, "⚠️ CAPTCHA/security page detected on #{url}")
      CSV.open("blocked_urls.csv", "ab") { |csv| csv << [url] }
      return true
    end

    false
  end

  def pick_user_agent
    @user_agents.sample
  end

  def pick_proxy_for_request(seed = nil)
    return nil if @proxy_list.nil? || @proxy_list.empty?

    # Keep one proxy per thread/session for a while
    @proxy_assignments ||= {}
    if session_id
      @proxy_assignments[session_id] ||= @proxy_list.sample
      @proxy_assignments[session_id]
    else
      @proxy_list.sample
    end
  end
end

# CLI
if __FILE__ == $0
  require_relative "qb_scraper_cli"
  
  QbScraperCLI.new(ARGV).run
end
