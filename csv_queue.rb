class CsvQueue
  def initialize(csv_filename:, input_source:, headers:)
    @csv_filename = csv_filename
    @input_source = input_source
    @headers = headers
    @mutex = Mutex.new

    ensure_csv_initialized
  end

  def load_urls
    urls = load_from_input_source.compact
    urls.map! do |u|
      u = u.strip
      u = "https://#{u}" unless u.match?(/^https?:\/\//i)
      u
    end

    puts "Running dedup ...."
    urls.uniq
  end

  def append(row_array)
    @mutex.synchronize do
      CSV.open(@csv_filename, "ab", headers: @headers, write_headers: false) do |csv|
        csv << row_array
      end
    end
  end

  def remove_source_url(url)
    return unless @input_source && File.exist?(@input_source)

    if csv_input_source?
      table = CSV.table(@input_source)
      CSV.open(@input_source, "wb", write_headers: true, headers: table.headers) do |csv_file|
        table.each do |row|
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

  private

  def ensure_csv_initialized
    return if File.exist?(@csv_filename)

    CSV.open(@csv_filename, "wb", write_headers: true, headers: @headers) do |_csv|
      # header written
    end
  end

  def load_from_input_source
    unless File.exist?(@input_source)
      puts "Error: File '#{@input_source}' not found!"
      return []
    end

    csv_input_source? ? load_from_csv_input : load_from_list_input
  end

  def load_from_csv_input
    csv = CSV.table(@input_source)
    urls = csv[:url] || csv[:link] || csv[:site] || []
    urls = urls.compact.map(&:to_s)

    existing_urls = existing_proadvisor_links
    urls.reject! { |u| existing_urls.include?(u) }
    urls.uniq!

    CSV.open(@input_source, "wb", write_headers: true, headers: csv.headers) do |csv_file|
      csv.each do |row|
        row_url = row[:url] || row[:link] || row[:site]
        csv_file << row if row_url && urls.include?(row_url.to_s)
      end
    end

    urls
  end

  def load_from_list_input
    urls = File.readlines(@input_source).map(&:strip).reject(&:empty?)

    existing_urls = existing_proadvisor_links
    urls.reject! { |u| existing_urls.include?(u) }
    urls.uniq!
    File.write(@input_source, urls.join("\n"))

    urls
  end

  def existing_proadvisor_links
    return [] unless File.exist?(@csv_filename)

    CSV.read(@csv_filename, headers: true).map { |row| row['proadvisor_link'] }.compact
  end

  def csv_input_source?
    @input_source.to_s.end_with?('.csv')
  end
end
