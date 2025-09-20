require 'launchy'

class CaptchaMitigation
  def initialize(blocked_page_detector:, sleep_interval: 30)
    @blocked_page_detector = blocked_page_detector
    @sleep_interval = sleep_interval
  end

  def handle(html:, url:, retries_left:, total_retries:)
    return { status: :ok, retries_left: retries_left } unless @blocked_page_detector.blocked?(html, url: url)

    puts "Blocked detected. Open browser and solve CAPTCHA (waiting #{@sleep_interval}s)..."
    Launchy.open(url)
    sleep(@sleep_interval)

    retries_left -= 1
    if retries_left <= 0
      puts "🚨 #{url} blocked #{total_retries} times. Exiting scraper gracefully."
      { status: :abort, retries_left: retries_left }
    else
      { status: :retry, retries_left: retries_left }
    end
  end
end