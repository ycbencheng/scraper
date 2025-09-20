require 'optparse'
require 'json'

class QbScraperCLI
  DEFAULT_OPTIONS = {
    concurrency: 1,
    headless: true,
    csv_filename: "proadvisor_results_incremental.csv"
  }.freeze

  def initialize(argv)
    @argv = argv.dup
    @options = DEFAULT_OPTIONS.dup
  end

  def run
    parser = build_option_parser
    parser.parse!(@argv)

    urls = @options[:urls] || []
    urls += @argv if @argv.any?

    if @options[:file]
      scraper = QbScraper.new(input_source: @options[:file], options: @options)
      scraper.run
    elsif urls.any?
      scraper = QbScraper.new(input_source: nil, options: @options)
      scraper.run(urls)
    else
      puts "No URLs or input file provided!"
      puts "Examples:"
      puts " ruby qb_scraper_safe_refactor.rb -f urls.csv -c 2 --csv results.csv"
      puts " ruby qb_scraper_safe_refactor.rb -u https://proadvisor.intuit.com/... "
    end
  rescue OptionParser::InvalidOption => e
    warn e.message
    puts parser
  end

  private

  def build_option_parser
    OptionParser.new do |opts|
      opts.banner = "Usage: ruby qb_scraper_safe_refactor.rb [options] [URLs...]"
      opts.on("-f", "--file FILE", "Input file (CSV or text file with URLs)") { |v| @options[:file] = v }
      opts.on("-u", "--url URL", "Single URL to scrape (can be used multiple times)") { |v| (@options[:urls] ||= []) << v }
      opts.on("-c", "--concurrency N", Integer, "Parallel threads (clamped to max 3)") { |v| @options[:concurrency] = v }
      opts.on("--proxy-list JSON", "JSON array of proxy strings (eg: '[\"host:port\"]')") { |v| @options[:proxy_list] = JSON.parse(v) rescue [] }
      opts.on("--min-between N", Float, "Min seconds between pages (default 5)") { |v| @options[:min_between] = v }
      opts.on("--max-between N", Float, "Max seconds between pages (default 18)") { |v| @options[:max_between] = v }
      opts.on("--csv FILE", "Output CSV filename (appends)") { |v| @options[:csv_filename] = v }
      opts.on("--no-headless", "Run non-headless (for debugging)") { @options[:headless] = false }
      opts.on("-h", "--help", "Show help") { puts opts; exit }
    end
  end
end
