begin
  require 'ferrum'
rescue LoadError
  module Ferrum
    class Browser
      def initialize(*)
        raise LoadError, 'Ferrum gem is required to create a browser session'
      end
    end
  end
end

class BrowserSession
  def initialize(headless:, timeout:, accept_language:, retries:, proxy: nil, user_agent: nil)
    @headless = headless
    @timeout = timeout
    @accept_language = accept_language
    @retries = retries
    @proxy = proxy
    @user_agent = user_agent
  end

  def build
    browser_opts = {
      headless: @headless,
      timeout: @timeout,
      window_size: [rand(800..1600), rand(600..1100)],
      browser_options: { 'no-sandbox': nil, 'disable-dev-shm-usage': nil }
    }

    if @proxy && !@proxy.to_s.strip.empty?
      browser_opts[:browser_options]['--proxy-server'] = @proxy
    end

    browser = Ferrum::Browser.new(**browser_opts)

    agent = @user_agent || browser.user_agent
    headers = { 'User-Agent' => agent, 'Accept-Language' => @accept_language }
    browser.headers.set(headers)

    browser
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
      if attempts_left.positive?
        puts "[Retry] Retrying #{url} (attempt #{attempt_number + 1}/#{max_attempts})"
        sleep(rand(3..6))
        retry
      else
        puts "[Failed] Could not fetch #{url} after #{attempt_number} attempts"
        nil
      end
    end
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

      body = browser.at_xpath('body') rescue nil
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

  private

  def sleep_for(range, retries_left = nil)
    seconds = rand(range)
    if retries_left && retries_left <= 0
      raise Interrupt
    else
      sleep(seconds)
    end
  end
end