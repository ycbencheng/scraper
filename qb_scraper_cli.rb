require 'optparse'
require 'json'

class QbScraperCLI
  DEFAULT_INPUT_FILE = "proadvisors_list.csv".freeze

  def initialize(argv)
    @argv = argv.dup
  end

  def run
    warn_if_arguments_present

    unless File.exist?(DEFAULT_INPUT_FILE)
      warn "Input file '#{DEFAULT_INPUT_FILE}' not found."
      return
    end

    scraper = QbScraper.new(input_source: DEFAULT_INPUT_FILE)
    scraper.run
  end

  private

  def warn_if_arguments_present
    return if @argv.empty?

    puts "Ignoring command line arguments; the scraper now always reads from #{DEFAULT_INPUT_FILE}."
  end
end
