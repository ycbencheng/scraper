require "httparty"
require "nokogiri"
require "parallel"
require "phonelib"
require 'sanitize'
require 'csv'
require 'optparse'
require 'ferrum'
require 'json'
require 'fileutils'
require "uri"

class QbScraper
  USER_AGENTS = [
    # Chrome (macOS)
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 12_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6074.119 Safari/537.36",
    # Chrome (Windows)
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.5993.117 Safari/537.36",
    # Firefox (Windows)
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) Gecko/20100101 Firefox/124.0",
    # Firefox (macOS)
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 13.6; rv:122.0) Gecko/20100101 Firefox/122.0",
    # Safari (macOS)
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Safari/605.1.15",
    # iPhone Safari
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/605.1.15",
    # Android Chrome
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
    "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.6045.117 Mobile Safari/537.36",
    # Edge (Windows)
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
  ].freeze

  DEFAULT_ACCEPT_LANGUAGE = "en-US,en;q=0.9"

  def initialize(input_source: nil, options: {})
    @input_source = input_source
    @concurrency = [[options.fetch(:concurrency, 1), 1].max, 3].min # clamp 1..3
    @user_agents = options.fetch(:user_agents, USER_AGENTS)
    @accept_language = options.fetch(:accept_language, DEFAULT_ACCEPT_LANGUAGE)
    @proxy_list = options.fetch(:proxy_list, []) # strings like "host:port" or "http://user:pass@host:port"
    @headless = options.fetch(:headless, true)
    @timeout = options.fetch(:timeout, 30)
    @min_between = options.fetch(:min_between, 5)
    @max_between = options.fetch(:max_between, 18)
    @retries = options.fetch(:retries, 2)
    @csv_filename = options.fetch(:csv_filename, "proadvisor_results_incremental.csv")
    @proadvisor = Struct.new(:accountant_name, :title_text, :emails, :social_sites, :proadvisor_link, :website_info, :error)
    @mutex = Mutex.new
    ensure_csv_initialized
  end

  def run(direct_urls = [])
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    urls = load_urls(direct_urls)
    return if urls.empty?

    puts "--- Total of #{urls.count} ProAdvisor URLs to scrape ---"
    puts "Concurrency: #{@concurrency}, Headless: #{@headless}, Proxies: #{@proxy_list.any?}"

    if @concurrency > 1
      scrape_in_parallel(urls)
    else
      scrape_sequential(urls)
    end

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
    %w(accountant_name title_text emails social_sites proadvisor_link website_info error)
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
      else
        urls = File.readlines(@input_source).map(&:strip).reject(&:empty?)
      end
    end

    urls.map! do |u|
      u = u.strip
      u = "https://#{u}" unless u.match?(/^https?:\/\//i)
      u
    end

    urls
  end

  def scrape_sequential(urls)
    browser = build_browser_for_context(proxy: pick_proxy_for_request(nil), user_agent: pick_user_agent)
    begin
      urls.each_with_index do |url, idx|
        puts "Processing #{idx + 1} of #{urls.count}: #{url}"
        html = fetch_with_retries(browser, url)
        pro = build_proadvisor_from_html(html, url)
        append_result_row(pro.to_a)
        puts "Saved: #{url}"
        sleep(rand(@min_between..@max_between))
      end
    ensure
      browser.quit if browser
    end
  end

  def scrape_in_parallel(urls)
    Parallel.each(urls, in_threads: @concurrency) do |url|
      proxy = pick_proxy_for_request(Thread.current.object_id)
      user_agent = pick_user_agent
      browser = build_browser_for_context(proxy: proxy, user_agent: user_agent)
      begin
        sleep(rand(0.3..2.0))
        html = fetch_with_retries(browser, url)
        pro = build_proadvisor_from_html(html, url)
        append_result_row(pro.to_a)
        puts "[worker #{Thread.current.object_id}] Saved: #{url}"
        sleep(rand(@min_between..@max_between))
      ensure
        browser.quit if browser
      end
    end
  end

  def build_browser_for_context(proxy: nil, user_agent: nil)
    browser_opts = {
      headless: @headless,
      timeout: @timeout,
      window_size: [rand(1000..1600), rand(700..1100)],
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

  def fetch_with_retries(browser, url, attempts_left = @retries + 1)
    attempts = 0
    begin
      attempts += 1
      browser.go_to(url)
      browser.network.wait_for_idle(duration: 4)
      simulate_reading_pause(browser)
      # guarded scroll
      begin
        if (body = browser.at_xpath("body"))
          body.scroll_to(y: rand(80..700))
          sleep(rand(0.15..0.7))
        end
      rescue => e
        warn "Scroll error: #{e.message}"
      end
      sleep(rand(0.05..0.4))
      browser.body
    rescue => e
      warn "Browser error (attempt #{attempts}) for #{url}: #{e.message}"
      if attempts_left > 1
        backoff = (2 ** (attempts - 1)) + rand(0.4..1.1)
        sleep(backoff)
        retry
      end
      nil
    end
  end

  def simulate_reading_pause(browser)
    roll = rand
    if roll < 0.6
      sleep(rand(1.0..4.0))
    elsif roll < 0.9
      sleep(rand(6..12))
    else
      sleep(rand(18..35))
    end

    # occasional viewport resize to add variability (non-fingerprinting)
    if rand < 0.08
      begin
        w = 1000 + rand(-150..300)
        h = 800 + rand(-150..200)
        browser.resize(w, h) if browser.respond_to?(:resize)
      rescue
      end
    end
  end

  def build_proadvisor_from_html(html, url)
    if html.nil? || html.strip.empty?
      return @proadvisor.new(nil, nil, nil, nil, url, nil, "Failed to fetch page content or empty body")
    end

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
    website_info = parse_website_info_from_body(body)
    @proadvisor.new(accountant_name, title_text, emails, social_sites, url, website_info, nil)
  rescue StandardError => e
    @proadvisor.new(nil, nil, nil, nil, url, nil, "Scraping Error - #{e.message}")
  end

  # helpers: parsing
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
    social_domains = %w[
      facebook.com
      twitter.com
      x.com
      linkedin.com
      instagram.com
      youtube.com
      pinterest.com
      tiktok.com
    ]

    all_links = body.xpath("//a[@href]").map { |l| l['href'].to_s.strip }.compact

    social = all_links.select do |url|
      begin
        host = URI.parse(url).host.to_s.downcase
        # skip empty hosts
        next false if host.empty?

        # allow exact domain or any subdomain (subdomain.facebook.com)
        social_domains.any? do |d|
          host == d || host.end_with?(".#{d}")
        end
      rescue URI::InvalidURIError
        false
      end
    end

    social.uniq.join("; ")
  end


  def parse_website_info_from_body(body)
    websites = []
    website_selectors = [
      "//a[contains(@class, 'website')]/@href","//a[contains(@class, 'url')]/@href",
      "//a[contains(text(), 'Website')]/@href","//a[contains(text(), 'Visit')]/@href",
      "//div[contains(@class, 'website')]//a/@href"
    ]
    website_selectors.each do |sel|
      links = body.xpath(sel)
      websites += links.map(&:value)
    end
    excluded = %w(facebook.com twitter.com linkedin.com instagram.com proadvisor.intuit.com intuit.com)
    websites = websites.select { |u| u.start_with?('http') && excluded.none? { |d| u.include?(d) } }
    websites.uniq.join("; ")
  end

  # helpers: UA / proxy selection
  def pick_user_agent
    @user_agents.sample
  end

  def pick_proxy_for_request(seed = nil)
    return nil if @proxy_list.nil? || @proxy_list.empty?
    seed ? @proxy_list[seed.hash.abs % @proxy_list.length] : @proxy_list.sample
  end
end

# CLI
if __FILE__ == $0
  options = { concurrency: 1, headless: true, csv_filename: "proadvisor_results_incremental.csv" }

  OptionParser.new do |opts|
    opts.banner = "Usage: ruby qb_scraper_safe_refactor.rb [options] [URLs...]"
    opts.on("-f", "--file FILE", "Input file (CSV or text file with URLs)") { |v| options[:file] = v }
    opts.on("-u", "--url URL", "Single URL to scrape (can be used multiple times)") { |v| (options[:urls] ||= []) << v }
    opts.on("-c", "--concurrency N", Integer, "Parallel threads (clamped to max 3)") { |v| options[:concurrency] = v }
    opts.on("--proxy-list JSON", "JSON array of proxy strings (eg: '[\"host:port\"]')") { |v| options[:proxy_list] = JSON.parse(v) rescue [] }
    opts.on("--min-between N", Float, "Min seconds between pages (default 5)") { |v| options[:min_between] = v }
    opts.on("--max-between N", Float, "Max seconds between pages (default 18)") { |v| options[:max_between] = v }
    opts.on("--csv FILE", "Output CSV filename (appends)") { |v| options[:csv_filename] = v }
    opts.on("--no-headless", "Run non-headless (for debugging)") { options[:headless] = false }
    opts.on("-h", "--help", "Show help") { puts opts; exit }
  end.parse!

  urls = options[:urls] || []
  urls += ARGV if ARGV.any?

  if options[:file]
    scraper = QbScraper.new(input_source: options[:file], options: options)
    scraper.run
  elsif urls.any?
    scraper = QbScraper.new(input_source: nil, options: options)
    scraper.run(urls)
  else
    puts "No URLs or input file provided!"
    puts "Examples:"
    puts " ruby qb_scraper_safe_refactor.rb -f urls.csv -c 2 --csv results.csv"
    puts " ruby qb_scraper_safe_refactor.rb -u https://proadvisor.intuit.com/... "
  end
end
