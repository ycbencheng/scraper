require "nokogiri"
require "parallel"
require 'csv'
require 'ferrum'
require 'launchy'
require "uri"
require 'byebug'

require_relative "qb_scraper_config"

class QbScraper
  def initialize(input_source: nil, options: {})
    @input_source = input_source
    @concurrency = [[options.fetch(:concurrency, 1), 1].max, 3].min # clamp 1..3
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
    @mutex = Mutex.new

    ensure_csv_initialized
  end

  def run(direct_urls = [])
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    urls = load_urls(direct_urls)
    return if urls.empty?

    puts "--- Total of #{urls.count} ProAdvisor URLs to scrape ---"
    puts "Concurrency: #{@concurrency}, Headless: #{@headless}, Proxies: #{@proxy_list.any?}"

    scrape_sequential(urls)

    total_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
    puts "Done. Total time - #{total_elapsed.round(2)} seconds"
  end

  private

  def ensure_csv_initialized
    # Create CSV with header if missing
    unless File.exist?(@csv_filename)
      CSV.open(@csv_filename, "wb", write_headers: true, headers: csv_headers) do |csv|
        # header written
      end
    end
  end

  def csv_headers
    %w(accountant_name title_text emails social_sites proadvisor_link site error)
  end

  def append_result_row(row_array)
    @mutex.synchronize do
      CSV.open(@csv_filename, "ab", headers: csv_headers, write_headers: false) do |csv|
        csv << row_array
      end
    end
  end

  def load_urls(direct_urls)
    urls = []
    if !direct_urls.empty?
      urls = direct_urls
    elsif @input_source
      unless File.exist?(@input_source)
        puts "Error: File '#{@input_source}' not found!"
        return []
      end

      if @input_source.end_with?('.csv')
        csv = CSV.table(@input_source)
        urls = csv[:url] || csv[:link] || csv[:site] || []
        urls = urls.compact.map(&:to_s)

        # Remove URLs already in incremental CSV
        existing_urls = File.exist?(@csv_filename) ? CSV.read(@csv_filename, headers: true).map { |row| row['proadvisor_link'] }.compact : []
        urls.reject! { |u| existing_urls.include?(u) }
        urls.uniq!

        # Overwrite original CSV with remaining URLs
        CSV.open(@input_source, "wb", write_headers: true, headers: csv.headers) do |csv_file|
          csv.each do |row|
            row_url = row[:url] || row[:link] || row[:site]
            csv_file << row if row_url && urls.include?(row_url.to_s)
          end
        end
      else
        urls = File.readlines(@input_source).map(&:strip).reject(&:empty?)
        # Remove URLs already in incremental CSV
        existing_urls = File.exist?(@csv_filename) ? CSV.read(@csv_filename, headers: true).map { |row| row['proadvisor_link'] }.compact : []
        urls.reject! { |u| existing_urls.include?(u) }
        urls.uniq!
        File.write(@input_source, urls.join("\n"))
      end
    end

    urls.map! do |u|
      u = u.strip
      u = "https://#{u}" unless u.match?(/^https?:\/\//i)
      u
    end

    puts "Running dedup ...."
    urls
  end

  def scrape_sequential(urls)
    total_urls = urls.size
    browser = build_browser_for_context(proxy: pick_proxy_for_request(nil), user_agent: pick_user_agent)

    begin
      urls.each_with_index do |url, idx|
        EventLogger.log(:outgoing, "Starting #{idx + 1}/#{total_urls}, Url: #{url}")
        retries_left = 3
        start_time_row = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        while retries_left > 0
          html = fetch_with_retries(browser, url)
          if html.nil?
            puts "Failed to fetch #{url}, skipping..."
            break
          end

          if blocked_page?(html, url)
            puts "Blocked detected. Open browser and solve CAPTCHA (waiting 30s)..."
            Launchy.open(url)
            sleep(30)

            retries_left -= 1
            if retries_left <= 0
              puts "🚨 #{url} blocked 3 times. Exiting scraper gracefully."
              browser.quit if browser
              exit 1
            else
              next
            end
          end

          # Successfully fetched
          pro = build_proadvisor_from_html(html, url)
          append_result_row(pro.to_a)
          remove_url_from_original(url)

          end_time_row = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          elapsed = end_time_row - start_time_row
          EventLogger.log(:success, "Saved! Time taken: #{elapsed.round(2)}s (#{idx + 1}/#{total_urls})")

          sleep(rand(@min_between..@max_between))
          break
        end
      end
    ensure
      browser.quit if browser
    end
  end

  def fetch_with_retries(browser, url, attempts_left = @retries + 1)
    attempts = 0

    begin
      attempts += 1
      browser.goto(url)
      browser.network.wait_for_idle(duration: rand(5.0..7.0))
      simulate_reading_pause(browser)

      html = browser.body
      return html

    rescue => e
      puts "[Error] #{e}"
      if attempts_left > 1
        puts "[Retry] Retrying #{url}, attempts left: #{attempts_left - 1}"
        sleep(rand(3..6))
        retry
      else
        puts "[Failed] Could not fetch #{url} after #{attempts} attempts"
        return nil
      end
    end
  end

  def build_browser_for_context(proxy: nil, user_agent: nil)
    browser_opts = {
      headless: @headless,
      timeout: @timeout,
      window_size: [rand(800..1600), rand(600..1100)],
      browser_options: { 'no-sandbox': nil, 'disable-dev-shm-usage': nil }
    }

    if proxy && !proxy.to_s.strip.empty?
      # Ferrum/Chromium passes proxy via --proxy-server
      browser_opts[:browser_options]['--proxy-server'] = proxy
    end

    browser = Ferrum::Browser.new(**browser_opts)

    user_agent ||= pick_user_agent
    browser.headers.set("User-Agent" => user_agent, "Accept-Language" => @accept_language)

    # NOTE: we intentionally DO NOT perform aggressive fingerprint evasion here.
    # Advanced evasion is fragile and likely to escalate defenses. Focus on polite timing & UA diversity.

    browser
  end

  def simulate_reading_pause(browser, retries_left = nil)
    begin
      roll = rand
      if roll < 0.6
        sleep_for(15.0..18.0, retries_left)
      elsif roll < 0.9
        sleep_for(18.0..21.0, retries_left)
      else
        sleep_for(21.0..24.0, retries_left)
      end

      body = browser.at_xpath("body") rescue nil
      if body
        current_pos = 0
        total_height = 1000 + rand(0..2000)
        3.upto(rand(5..10)) do
          increment = rand(50..200)
          current_pos += increment
          body.scroll_to(y: [current_pos, total_height].min)
          sleep_for(0.75..3.0, retries_left)
        end
      end

      if rand < 0.08
        w = 1000 + rand(-150..300)
        h = 800 + rand(-150..200)
        browser.resize(w, h) if browser.respond_to?(:resize)
      end
    rescue Interrupt
      puts "⚠️ Scraper interrupted!"
      browser.quit if browser
      exit 1
    end
  end

  def sleep_for(range, retries_left = nil)
    seconds = rand(range)
    if retries_left && retries_left <= 0
      raise Interrupt
    else
      sleep(seconds)
    end
  end

  def build_proadvisor_from_html(html, url)
    body = Nokogiri::HTML(html)

    accountant_name = extract_text_by_selectors(body, [
      "h1.accountant-name","h1[class*='name']","div.profile-name h1","div[class*='accountant'] h1",
      "h2.accountant-name","span.accountant-name","div.name-container","h1",".profile-header h1"
    ])
    title_text = extract_text_by_selectors(body, [
      "div.title","span.title","p.designation","div.professional-title","span.job-title","div[class*='title']","span[class*='designation']","//*[@data-testid='professional-title']"
    ])
    emails = parse_emails_from_body(body)
    social_sites = parse_social_sites_from_body(body)
    site = parse_site_from_body(body)
    @proadvisor.new(accountant_name, title_text, emails, social_sites, url, site, nil)
  rescue StandardError => e
    @proadvisor.new(nil, nil, nil, nil, url, nil, "Scraping Error - #{e.message}")
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

  def extract_text_by_selectors(body, selectors)
    selectors.each do |sel|
      begin
        element = sel.start_with?('//') ? body.xpath(sel).first : body.css(sel).first
        next unless element
        text = element.text.strip
        return text unless text.empty?
      rescue
        next
      end
    end
    nil
  end

  def parse_emails_from_body(body)
    emails = []
    mailto = body.xpath("//a[starts-with(@href, 'mailto:')]/@href")
    emails += mailto.map { |l| l.value.sub('mailto:', '') }
    email_pattern = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/
    emails += body.text.scan(email_pattern)
    contacts = body.xpath("//div[contains(@class, 'contact')]//text() | //section[contains(@class, 'contact')]//text()")
    contacts.each { |t| emails += t.to_s.scan(email_pattern) }
    emails.uniq.join("; ")
  end

  def parse_social_sites_from_body(body)
    all_links = body.xpath("//a[@href]").map { |l| l['href'].to_s.strip }.compact

    social = all_links.select do |url|
      begin
        host = URI.parse(url).host.to_s.downcase
        # skip empty hosts
        next false if host.empty?

        # allow exact domain or any subdomain (subdomain.facebook.com)
        QbScraperConfig::SOCIAL_DOMAINS.any? do |d|
          host == d || host.end_with?(".#{d}")
        end
      rescue URI::InvalidURIError
        false
      end
    end

    social.uniq.join("; ")
  end

  def parse_site_from_body(body)
    websites = []
    QbScraperConfig::WEBSITE_SELECTORS.each do |sel|
      links = body.xpath(sel)
      websites += links.map(&:value)
    end

    websites = websites.select do |u|
      u.start_with?('http') && QbScraperConfig::WEBSITE_EXCLUDED_DOMAINS.none? { |d| u.include?(d) }
    end

    websites.uniq.join("; ")
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

  def remove_url_from_original(url)
    return unless @input_source && File.exist?(@input_source)
    
    if @input_source.end_with?('.csv')
      csv = CSV.table(@input_source)
      CSV.open(@input_source, "wb", write_headers: true, headers: csv.headers) do |csv_file|
        csv.each do |row|
          row_url = row[:url] || row[:link] || row[:site]
          csv_file << row unless row_url.to_s.strip == url.to_s.strip
        end
      end
    else
      lines = File.readlines(@input_source).map(&:strip)
      lines.reject! { |line| line.strip == url.strip }
      File.write(@input_source, lines.join("\n"))
    end
  end
end

# CLI
if __FILE__ == $0
  require_relative "qb_scraper_cli"
  
  QbScraperCLI.new(ARGV).run
end
