module Excon
  class Connection

    unless defined?(:CHUNK_SIZE)
      CHUNK_SIZE = 1048576 # 1 megabyte
    end

    def initialize(url)
      @uri = URI.parse(url)
    end

    def request(params)
      begin
        params[:path] ||= ''
        unless params[:path][0..0] == '/'
          params[:path] = "/#{params[:path]}"
        end
        if params[:query] && !params[:query].empty?
          params[:path] << "?#{params[:query]}"
        end
        request = "#{params[:method]} #{params[:path]} HTTP/1.1\r\n"
        params[:headers] ||= {}
        params[:headers]['Host'] = params[:host] || @uri.host
        if params[:body] && !params[:headers]['Content-Length']
          params[:headers]['Content-Length'] = params[:body].length
        end
        for key, value in params[:headers]
          request << "#{key}: #{value}\r\n"
        end
        request << "\r\n"
        connection.write(request)

        if params[:body]
          if params[:body].is_a?(String)
            connection.write(params[:body])
          else
            while chunk = params[:body].read(CHUNK_SIZE)
              connection.write(chunk)
            end
          end
        end

        response = Excon::Response.new
        response.status = connection.readline[9..11].to_i
        while true
          data = connection.readline.chop!
          unless data.empty?
            header = data.split(': ')
            response.headers[header[0]] = header[1]
          else
            break
          end
        end

        unless params[:method] == 'HEAD'
          unless params[:block] || ![*params[:expects]].compact.include?(response.status)
            response.body = ''
            params[:block] = lambda { |chunk| response.body << chunk }
          end

          if response.headers['Content-Length']
            remaining = response.headers['Content-Length'].to_i
            while remaining > 0
              params[:block].call(connection.read([CHUNK_SIZE, remaining].min))
              remaining -= CHUNK_SIZE
            end
          elsif response.headers['Transfer-Encoding'] == 'chunked'
            while true
              chunk_size = connection.readline.chomp!.to_i(16)
              chunk = connection.read(chunk_size + 2).chop! # 2 == "/r/n".length
              if chunk_size > 0
                params[:block].call(chunk)
              else
                break
              end
            end
          elsif response.headers['Connection'] == 'close'
            params[:block].call(connection.read)
            @connection = nil
          end
        end
      rescue => connection_error
        @connection = nil
        raise(connection_error)
      end

      if params[:expects] && ![*params[:expects]].include?(response.status)
        raise(Excon::Errors.status_error(params[:expects], response.status, response))
      else
        response
      end
    end

    private

    def connection
      if !@connection || @connection.closed?
        @connection = TCPSocket.open(@uri.host, @uri.port)
        if @uri.scheme == 'https'
          @ssl_context = OpenSSL::SSL::SSLContext.new
          @ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
          @connection = OpenSSL::SSL::SSLSocket.new(@connection, @ssl_context)
          @connection.sync_close = true
          @connection.connect
        end
      end
      @connection
    end

  end
end
