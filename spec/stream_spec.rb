require "helper"

describe Net::HTTP2::Stream do
  before(:each) do
    @conn = Connection.new
    @stream = @conn.allocate_stream
  end

  context "stream states" do
    it "should initiliaze all streams to IDLE" do
      @stream.state.should eq :idle
    end

    context "reserved (local)" do
      before(:each) { @stream.send PUSH_PROMISE }

      it "should transition on sent PUSH_PROMISE" do
        @stream.state.should eq :reserved_local
      end

      it "should allow HEADERS to be sent" do
        expect { @stream.send HEADERS }.to_not raise_error
      end

      it "should raise error if sending invalid frames" do
        (FRAME_TYPES - [HEADERS, RST_STREAM]).each do |type|
          expect { @stream.dup.send type }.to raise_error StreamError
        end
      end

      it "should raise error on receipt of invalid frames" do
        (FRAME_TYPES - [PRIORITY, RST_STREAM]).each do |type|
          expect { @stream.dup.process type }.to raise_error StreamError
        end
      end

      it "should transition to half closed (remote) on sent HEADERS" do
        @stream.send HEADERS
        @stream.state.should eq :half_closed_remote
      end

      it "should transition to closed on sent RST_STREAM" do
        @stream.close
        @stream.state.should eq :closed
      end

      it "should transition to closed on received RST_STREAM" do
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should reprioritize stream on PRIORITY" do
        @stream.process PRIORITY.merge({priority: 30})
        @stream.priority.should eq 30
      end
    end

    context "reserved (remote)" do
      before(:each) { @stream.process PUSH_PROMISE }

      it "should transition on received PUSH_PROMISE" do
        @stream.state.should eq :reserved_remote
      end

      it "should raise error if sending invalid frames" do
        (FRAME_TYPES - [PRIORITY, RST_STREAM]).each do |type|
          expect { @stream.dup.send type }.to raise_error StreamError
        end
      end

      it "should raise error on receipt of invalid frames" do
        (FRAME_TYPES - [HEADERS, RST_STREAM]).each do |type|
          expect { @stream.dup.process type }.to raise_error StreamError
        end
      end

      it "should transition to half closed (local) on received HEADERS" do
        @stream.process HEADERS
        @stream.state.should eq :half_closed_local
      end

      it "should transition to closed on sent RST_STREAM" do
        @stream.close
        @stream.state.should eq :closed
      end

      it "should transition to closed on received RST_STREAM" do
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should reprioritize stream on PRIORITY" do
        @stream.send PRIORITY
        @stream.priority.should eq 15
      end
    end

    context "open" do
      before(:each) { @stream.process HEADERS }

      it "should allow frames of any type to be sent" do
        FRAME_TYPES.each do |type|
          expect { @stream.dup.send type }.to_not raise_error
        end
      end

      it "should allow frames of any type to be received" do
        FRAME_TYPES.each do |type|
          expect { @stream.dup.process type }.to_not raise_error
        end
      end

      it "should transition to half closed (local) if sending END_STREAM" do
        [DATA, HEADERS, CONTINUATION].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.send f
          s.state.should eq :half_closed_local
        end
      end

      it "should transition to half closed (remote) if receiving END_STREAM" do
        [DATA, HEADERS, CONTINUATION].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.process f
          s.state.should eq :half_closed_remote
        end
      end

      it "should transition to half closed if remote opened with END_STREAM" do
        s = @conn.allocate_stream
        hclose = HEADERS.dup
        hclose[:flags] = [:end_stream]

        s.process hclose
        s.state.should eq :half_closed_remote
      end

      it "should transition to half closed if local opened with END_STREAM" do
        s = @conn.allocate_stream
        hclose = HEADERS.dup
        hclose[:flags] = [:end_stream]

        s.send hclose
        s.state.should eq :half_closed_local
      end

      it "should transition to closed if sending RST_STREAM" do
        @stream.close
        @stream.state.should eq :closed
      end

      it "should transition to closed if receiving RST_STREAM" do
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should fire on_open callback on open transition" do
        openp, openr = false, false
        sp = @conn.allocate_stream
        sr = @conn.allocate_stream
        sp.on_open { openp = true }
        sr.on_open { openr = true }

        sp.process HEADERS
        sr.send HEADERS

        openp.should be_true
        openr.should be_true
      end

      it "should fire on_close callback on close transition" do
        closep, closer = false, false
        sp, sr = @stream.dup, @stream.dup

        sp.on_close { closep = true }
        sr.on_close { closer = true }

        sp.process RST_STREAM
        sr.close

        closep.should be_true
        closer.should be_true
      end

      it "should emit reason in on_close callback" do
        reason = nil
        @stream.on_close {|r| reason = r }
        @stream.process RST_STREAM
        reason.should_not be_nil
      end
    end

    context "half closed (local)" do
      before(:each) { @stream.send HEADERS_END_STREAM }

      it "should raise error on attempt to send frames" do
        (FRAME_TYPES - [RST_STREAM]).each do |frame|
          expect { @stream.dup.send frame }.to raise_error StreamError
        end
      end

      it "should transition to closed on receipt of END_STREAM flag" do
        [DATA, HEADERS, CONTINUATION].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.process f
          s.state.should eq :closed
        end
      end

      it "should transition to closed on receipt of RST_STREAM frame" do
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should transition to closed if RST_STREAM frame is sent" do
        @stream.send RST_STREAM
        @stream.state.should eq :closed
      end

      it "should ignore received WINDOW_UPDATE, PRIORITY frames" do
        expect { @stream.process WINDOW_UPDATE }.to_not raise_error
        expect { @stream.process PRIORITY }.to_not raise_error
        @stream.state.should eq :half_closed_local
      end

      it "should fire on_close callback on close transition" do
        closed = false
        @stream.on_close { closed = true }
        @stream.process RST_STREAM

        @stream.state.should eq :closed
        closed.should be_true
      end
    end

    context "half closed (remote)" do
      before(:each) { @stream.process HEADERS_END_STREAM }

      it "should raise STREAM_CLOSED error on reciept of frames" do
        (FRAME_TYPES - [RST_STREAM, WINDOW_UPDATE]).each do |frame|
          expect {
            @stream.dup.process frame
          }.to raise_error(StreamError, /stream closed/i)
        end
      end

      it "should transition to closed if END_STREAM flag is sent" do
        [DATA, HEADERS, CONTINUATION].each do |frame|
          s, f = @stream.dup, frame.dup
          f[:flags] = [:end_stream]

          s.send f
          s.state.should eq :closed
        end
      end

      it "should transition to closed if RST_STREAM is sent" do
        @stream.close
        @stream.state.should eq :closed
      end

      it "should transition to closed on reciept of RST_STREAM frame" do
        @stream.process RST_STREAM
        @stream.state.should eq :closed
      end

      it "should ignore received WINDOW_UPDATE frames" do
        expect { @stream.process WINDOW_UPDATE }.to_not raise_error
        @stream.state.should eq :half_closed_remote
      end

      it "should fire on_close callback on close transition" do
        closed = false
        @stream.on_close { closed = true }
        @stream.close

        @stream.state.should eq :closed
        closed.should be_true
      end
    end

    context "closed" do
      context "remote closed stream" do
        before(:each) do
          @stream.send HEADERS_END_STREAM     # half closed local
          @stream.process HEADERS_END_STREAM  # closed by remote
        end

        it "should raise STREAM_CLOSED on attempt to send frames" do
          (FRAME_TYPES - [RST_STREAM]).each do |frame|
            expect {
              @stream.dup.send frame
            }.to raise_error(StreamError, /stream closed/i)
          end
        end

        it "should raise STREAM_CLOSED on receipt of frame" do
          (FRAME_TYPES - [RST_STREAM]).each do |frame|
            expect {
              @stream.dup.process frame
            }.to raise_error(StreamError, /stream closed/i)
          end
        end

        it "should allow RST_STREAM to be sent" do
          expect { @stream.send RST_STREAM }.to_not raise_error
        end

        it "should not send RST_STREAM on receipt of RST_STREAM" do
          expect { @stream.process RST_STREAM }.to_not raise_error
        end
      end

      context "local closed via RST_STREAM frame" do
        before(:each) do
          @stream.send HEADERS     # open
          @stream.send RST_STREAM  # closed by local
        end

        it "should ignore received frames" do
          (FRAME_TYPES - [PUSH_PROMISE]).each do |frame|
            expect {
              @stream.dup.process frame
            }.to_not raise_error
          end
        end

        it "should transition to reserved remote on PUSH_PROMISE" do
          # An endpoint might receive a PUSH_PROMISE frame after it sends
          # RST_STREAM.  PUSH_PROMISE causes a stream to become "reserved".
          # The RST_STREAM does not cancel any promised stream.  Therefore, if
          # promised streams are not desired, a RST_STREAM can be used to
          # close any of those streams.

          pending "huh?"
        end
      end

     context "local closed via END_STREAM flag" do
        before(:each) do
          @stream.send HEADERS  # open
          @stream.send DATA     # contains end_stream flag
        end

        it "should ignore received frames" do
          FRAME_TYPES.each do |frame|
            expect { @stream.dup.process frame }.to_not raise_error
          end
        end
      end
    end
  end # end stream states

  context "flow control" do
    it "should initialize to default flow control window" do
      @stream.window.should eq DEFAULT_FLOW_WINDOW
    end

    it "should update window size on DATA frames only" do
      @stream.send HEADERS # go to open
      @stream.window.should eq DEFAULT_FLOW_WINDOW

      (FRAME_TYPES - [DATA]).each do |frame|
        s = @stream.dup
        s.send frame
        s.window.should eq DEFAULT_FLOW_WINDOW
      end

      @stream.send DATA
      @stream.window.should eq DEFAULT_FLOW_WINDOW - DATA[:payload].bytesize
    end

    it "should update window size on receipt of WINDOW_UPDATE" do
      @stream.send HEADERS
      @stream.send DATA
      @stream.process WINDOW_UPDATE

      @stream.window.should eq (
        DEFAULT_FLOW_WINDOW - DATA[:payload].bytesize + WINDOW_UPDATE[:increment]
      )
    end
  end

  context "API" do
    it ".priority should emit PRIORITY frame" do
      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :priority
        frame[:priority].should eq 30
      end

      @stream.priority = 30
    end

    it ".headers should emit HEADERS frames" do
      payload = {
        ':method' => 'GET',
        ':scheme' => 'http',
        ':host'   => 'www.example.org',
        ':path'   => '/resource',
        'custom'  => 'value'
      }

      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :headers
        frame[:payload].should eq payload
        frame[:flags].should eq [:end_headers]
      end

      @stream.headers(payload, end_stream: false, end_headers: true)
    end

    it ".promise should emit PUSH_PROMISE frame" do
      payload = {
        ':status'        => 200,
        'content-length' => 123,
        'content-type'   => 'image/jpg'
      }

      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :push_promise
        frame[:payload].should eq payload
        frame[:promise_stream].should be_nil
      end

      @stream.promise(payload)
    end

    it ".promise should return a new push stream object"

    it ".data should emit DATA frames" do
      @stream.should_receive(:send) do |frame|
        frame[:type].should eq :data
        frame[:payload].should eq "text"
        frame[:flags].should be_empty
      end
      @stream.data("text", end_stream: false)

      @stream.should_receive(:send) do |frame|
        frame[:flags].should eq [:end_stream]
      end
      @stream.data("text")
    end

    it ".data should observe session flow control"
  end
end