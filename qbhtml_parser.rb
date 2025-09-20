require 'nokogiri'
require 'csv'

class QbhtmlParser
  def initialize(html_file_path)
    @html_file_path = html_file_path
    @target_badges = %w[desktop pro premier enterprise]
    @results = []
  end

  def parse_and_extract
    unless File.exist?(@html_file_path)
      puts "Error: HTML file '#{@html_file_path}' not found!"
      return []
    end

    html_content = File.read(@html_file_path)
    doc = Nokogiri::HTML(html_content)
    
    # Find all search cards
    search_cards = doc.css('.qba-matchmaking-ui-search-card')
    
    puts "Found #{search_cards.length} accountant cards"
    
    search_cards.each do |card|
      process_card(card)
    end
    
    puts "Extracted #{@results.length} accountants with target badges"
    @results
  end

  def save_to_csv(filename = 'proadvisors_list.csv')
    return if @results.empty?

    write_headers = !File.exist?(filename)
    
    CSV.open(filename, 'ab', write_headers: write_headers, headers: %w[url]) do |csv|
      @results.each do |href|
        csv << [href]
      end
    end

    puts "Appended #{@results.length} URLs to #{filename}"
  end

  def print_results
    return if @results.empty?
    
    puts "\n" + "="*80
    puts "FILTERED URLs (#{@results.length} found)"
    puts "="*80
    
    @results.each_with_index do |href, index|
      puts "#{index + 1}. #{href}"
    end
  end

  private

  def process_card(card)
    # Extract accountant name and href
    name_element = card.css('.accountant-name a').first
    return unless name_element
    
    accountant_name = name_element.parent.text.strip
    href = name_element['href']
    
    # Extract and check badges
    badge_elements = card.css('.qba-matchmaking-ui-badge .badge-text')
    badges = extract_badge_info(badge_elements)
    
    # Check if any badge contains our target keywords
    if has_target_badge?(badges)
      @results << "https://proadvisor.intuit.com"+ href
      puts "✓ #{accountant_name} - #{href}"
    else
      puts "✗ #{accountant_name} - No matching badges"
    end
  end

  def extract_badge_info(badge_elements)
    badges = []
    
    badge_elements.each do |badge|
      # Get the main badge text and type
      badge_lines = badge.css('div').map { |div| div.text.strip }
      badge_text = badge_lines.join(' ').strip
      badges << badge_text unless badge_text.empty?
    end
    
    badges
  end

  def has_target_badge?(badges)
    badges.any? do |badge|
      badge_lower = badge.downcase
      @target_badges.any? { |target| badge_lower.include?(target) }
    end
  end
end

# Usage example
if __FILE__ == $0
  if ARGV.empty?
    puts "Usage: ruby qbhtml_parser.rb <html_file_path> [output_csv]"
    puts "Example: ruby qbhtml_parser.rb search_results.html proadvisors_list.csv"
    exit
  end

  html_file = ARGV[0]
  csv_file = ARGV[1] || 'proadvisors_list.csv'

  parser = QbhtmlParser.new(html_file)
  results = parser.parse_and_extract
  
  if results.any?
    parser.print_results
    parser.save_to_csv(csv_file)
  else
    puts "No accountants found with target badges (desktop, pro, premier, enterprise)"
  end
end