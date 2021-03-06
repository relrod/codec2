% test_ldpc.m
% David Rowe Oct 2014
%

% Simulation to test FDM QPSK with pilot based coherent detection,
% DSSS, and rate 1/2 LDPC
%
% TODO
%   [X] Nc carriers, 588 bit frames
%   [X] FEC
%   [X] pilot insertion and removal
%   [ ] delay on parity carriers
%   [X] pilot based phase est
%   [ ] uncoded and coded frame sync
%   [X] timing estimation, RN filtering, carrier FDM
%   [ ] this file getting too big - refactor
%   [ ] robust coarse timing
%   [ ] Np knob on GUI
 
% reqd to make sure we can repeat tests exactly

rand('state',1); 
randn('state',1);

1;

% Symbol rate processing for tx side (modulator)

function [tx_symb tx_bits prev_sym_tx] = symbol_rate_tx(sim_in, tx_bits, code_param, prev_sym_tx)
    ldpc_code     = sim_in.ldpc_code;
    rate          = sim_in.ldpc_code_rate;
    framesize     = sim_in.framesize;
    Nsymbrow      = sim_in.Nsymbrow;
    Nsymbrowpilot = sim_in.Nsymbrowpilot;
    Nc            = sim_in.Nc;
    Npilotsframe  = sim_in.Npilotsframe;
    Ns            = sim_in.Ns;
    Nchip         = sim_in.Nchip;
    modulation    = sim_in.modulation;
    pilot         = sim_in.pilot;

    if ldpc_code
        [tx_bits, tmp] = ldpc_enc(tx_bits, code_param);
    end

    % modulate --------------------------------------------

    % organise symbols into a Nsymbrow rows by Nc cols
    % data and parity bits are on separate carriers

    tx_symb = zeros(Nsymbrow,Nc);

    for c=1:Nc
      for r=1:Nsymbrow
        i = (c-1)*Nsymbrow + r;
        tx_symb(r,c) = qpsk_mod(tx_bits(2*(i-1)+1:2*i));
      end
    end

    % Optionally insert pilots, one every Ns data symbols

    tx_symb_pilot = zeros(Nsymbrowpilot, Nc);
            
    for p=1:Npilotsframe
      tx_symb_pilot((p-1)*(Ns+1)+1,:)          = pilot(p,:);                 % row of pilots
      %printf("%d %d %d %d\n", (p-1)*(Ns+1)+2, p*(Ns+1), (p-1)*Ns+1, p*Ns);
      tx_symb_pilot((p-1)*(Ns+1)+2:p*(Ns+1),:) = tx_symb((p-1)*Ns+1:p*Ns,:); % payload symbols
    end
    tx_symb = tx_symb_pilot;

    % Optionally copy to other carriers (spreading)

    for c=Nc+1:Nc:Nc*Nchip
      tx_symb(:,c:c+Nc-1) = tx_symb(:,1:Nc);
    end
            
    % Optionally DQPSK encode
 
    if strcmp(modulation,'dqpsk')
      for c=1:Nc*Nchip
        for r=1:Nsymbrowpilot
          tx_symb(r,c) *= prev_sym_tx(c);
          prev_sym_tx(c) = tx_symb(r,c);
        end
      end               
    end

    % ensures energy/symbol is normalised when spreading

    tx_symb = tx_symb/sqrt(Nchip);
end


% Init HF channel model from stored sample files of spreading signal ----------------------------------

function [spread spread_2ms hf_gain] = init_hf_model(Fs, Rs, nsam)

    % convert "spreading" samples from 1kHz carrier at Fs to complex
    % baseband, generated by passing a 1kHz sine wave through PathSim
    % with the ccir-poor model, enabling one path at a time.
    
    Fc = 1000; M = Fs/Rs;
    fspread = fopen("../raw/sine1k_2Hz_spread.raw","rb");
    spread1k = fread(fspread, "int16")/10000;
    fclose(fspread);
    fspread = fopen("../raw/sine1k_2ms_delay_2Hz_spread.raw","rb");
    spread1k_2ms = fread(fspread, "int16")/10000;
    fclose(fspread);

    % down convert to complex baseband
    spreadbb = spread1k.*exp(-j*(2*pi*Fc/Fs)*(1:length(spread1k))');
    spreadbb_2ms = spread1k_2ms.*exp(-j*(2*pi*Fc/Fs)*(1:length(spread1k_2ms))');

    % remove -2000 Hz image
    b = fir1(50, 5/Fs);
    spread = filter(b,1,spreadbb);
    spread_2ms = filter(b,1,spreadbb_2ms);
   
    % discard first 1000 samples as these were near 0, probably as
    % PathSim states were ramping up

    spread    = spread(1000:length(spread));
    spread_2ms = spread_2ms(1000:length(spread_2ms));

    % decimate down to Rs
    
    spread = spread(1:M:length(spread));
    spread_2ms = spread_2ms(1:M:length(spread_2ms));

    % Determine "gain" of HF channel model, so we can normalise
    % carrier power during HF channel sim to calibrate SNR.  I imagine
    % different implementations of ccir-poor would do this in
    % different ways, leading to different BER results.  Oh Well!

    hf_gain = 1.0/sqrt(var(spread(1:nsam))+var(spread_2ms(1:nsam)));
endfunction


% init function for symbol rate processing

function sim_in = symbol_rate_init(sim_in)
    sim_in.Fs = Fs = 8000;

    modulation       = sim_in.modulation;
    verbose          = sim_in.verbose;
    framesize        = sim_in.framesize;
    Ntrials          = sim_in.Ntrials;
    Esvec            = sim_in.Esvec;
    phase_offset     = sim_in.phase_offset;
    w_offset         = sim_in.w_offset;
    plot_scatter     = sim_in.plot_scatter;

    Rs               = sim_in.Rs;
    Nc               = sim_in.Nc;

    hf_sim           = sim_in.hf_sim;
    nhfdelay         = sim_in.hf_delay_ms*Rs/1000;
    hf_mag_only      = sim_in.hf_mag_only;

    Nchip            = sim_in.Nchip;  % spread spectrum factor
    Np               = sim_in.Np;     % number of pilots to use
    Ns               = sim_in.Ns;     % step size between pilots
    ldpc_code        = sim_in.ldpc_code;
    rate             = sim_in.ldpc_code_rate; 

    sim_in.bps = bps = 2;

    sim_in.Nsymb         = Nsymb            = framesize/bps;
    sim_in.Nsymbrow      = Nsymbrow         = Nsymb/Nc;
    sim_in.Npilotsframe  = Npilotsframe     = Nsymbrow/Ns;
    sim_in.Nsymbrowpilot = Nsymbrowpilot    = Nsymbrow + Npilotsframe;

    printf("Each frame is %d bits or %d symbols, transmitted as %d symbols by %d carriers.",
           framesize, Nsymb, Nsymbrow, Nc);
    printf("  There are %d pilot symbols in each carrier, seperated by %d data/parity symbols.",
           Npilotsframe, Ns);
    printf("  Including pilots, the frame is %d symbols long by %d carriers.\n\n", 
           Nsymbrowpilot, Nc);

    assert(Npilotsframe == floor(Nsymbrow/Ns), "Npilotsframe must be an integer");

    sim_in.prev_sym_tx = qpsk_mod([0 0])*ones(1,Nc*Nchip);
    sim_in.prev_sym_rx = qpsk_mod([0 0])*ones(1,Nc*Nchip);

    sim_in.rx_symb_buf  = zeros(3*Nsymbrow, Nc*Nchip);
    sim_in.rx_pilot_buf = zeros(3*Npilotsframe,Nc*Nchip);
    sim_in.tx_bits_buf  = zeros(1,2*framesize);

    % pilot sequence is used for phase and amplitude estimation, and frame sync

    pilot = 1 - 2*(rand(Npilotsframe,Nc) > 0.5);
    sim_in.pilot = pilot;
    sim_in.tx_pilot_buf = [pilot; pilot; pilot];
   
    % Init LDPC --------------------------------------------------------------------

    if ldpc_code
        % Start CML library

        currentdir = pwd;
        addpath '/home/david/tmp/cml/mat'    % assume the source files stored here
        cd /home/david/tmp/cml
        CmlStartup                           % note that this is not in the cml path!
        cd(currentdir)
  
        % Our LDPC library

        ldpc;

        mod_order = 4; 
        modulation2 = 'QPSK';
        mapping = 'gray';

        sim_in.demod_type = 0;
        sim_in.decoder_type = 0;
        sim_in.max_iterations = 100;

        code_param = ldpc_init(rate, framesize, modulation2, mod_order, mapping);
        code_param.code_bits_per_frame = framesize;
        code_param.symbols_per_frame = framesize/bps;
        sim_in.code_param = code_param;
    else
        sim_in.rate = 1;
    end
endfunction


function [rx_symb rx_bits rx_symb_linear amp_linear amp_ phi_ prev_sym_rx sim_in] = symbol_rate_rx(sim_in, s_ch, prev_sym_rx)
    framesize     = sim_in.framesize;
    Nsymb         = sim_in.Nsymb;
    Nsymbrow      = sim_in.Nsymbrow;
    Nsymbrowpilot = sim_in.Nsymbrowpilot;
    Nc            = sim_in.Nc;
    Npilotsframe  = sim_in.Npilotsframe;
    Ns            = sim_in.Ns;
    Np            = sim_in.Np;
    Nchip         = sim_in.Nchip;
    modulation    = sim_in.modulation;
    pilot         = sim_in.pilot;
    rx_symb_buf   = sim_in.rx_symb_buf;
    rx_pilot_buf  = sim_in.rx_pilot_buf;
    tx_pilot_buf  = sim_in.tx_pilot_buf;
    verbose       = sim_in.verbose;

    % demodulate stage 1

    for r=1:Nsymbrowpilot
      for c=1:Nc*Nchip
        rx_symb(r,c) = s_ch(r, c);
        if strcmp(modulation,'dqpsk')
          tmp = rx_symb(r,c);
          rx_symb(r,c) *= conj(prev_sym_rx(c)/abs(prev_sym_rx(c)));
          prev_sym_rx(c) = tmp;
        end
      end
    end
           
    % strip out pilots

    rx_symb_pilot = rx_symb;
    rx_symb = zeros(Nsymbrow, Nc*Nchip);
    rx_pilot = zeros(Npilotsframe, Nc*Nchip);

    for p=1:Npilotsframe
      % printf("%d %d %d %d %d\n", (p-1)*Ns+1, p*Ns, (p-1)*(Ns+1)+2, p*(Ns+1), (p-1)*(Ns+1)+1);
      rx_symb((p-1)*Ns+1:p*Ns,:) = rx_symb_pilot((p-1)*(Ns+1)+2:p*(Ns+1),:);
      rx_pilot(p,:) = rx_symb_pilot((p-1)*(Ns+1)+1,:);
    end

    % buffer three frames of symbols (and pilots) for phase recovery

    rx_symb_buf(1:2*Nsymbrow,:) = rx_symb_buf(Nsymbrow+1:3*Nsymbrow,:);
    rx_symb_buf(2*Nsymbrow+1:3*Nsymbrow,:) = rx_symb;
    rx_pilot_buf(1:2*Npilotsframe,:) = rx_pilot_buf(Npilotsframe+1:3*Npilotsframe,:);
    rx_pilot_buf(2*Npilotsframe+1:3*Npilotsframe,:) = rx_pilot;
    sim_in.rx_symb_buf = rx_symb_buf;
    sim_in.rx_pilot_buf = rx_pilot_buf;

    % pilot assisted phase estimation and correction of middle frame in rx symb buffer

    rx_symb = rx_symb_buf(Nsymbrow+1:2*Nsymbrow,:);
            
    phi_ = zeros(Nsymbrow, Nc*Nchip);
    amp_ = ones(Nsymbrow, Nc*Nchip);

    for c=1:Nc*Nchip

      if verbose > 2
        printf("phi_   : ");
      end

      for r=1:Nsymbrow
        st = Npilotsframe+1+floor((r-1)/Ns) - floor(Np/2) + 1;
        en = st + Np - 1;
        phi_(r,c) = angle(sum(tx_pilot_buf(st:en,c)'*rx_pilot_buf(st:en,c)));
        amp_(r,c) = abs(tx_pilot_buf(st:en,c)'*rx_pilot_buf(st:en,c))/Np;
        %amp_(r,c) = abs(rx_symb(r,c));
        if verbose > 2
          printf("% 4.3f ", phi_(r,c))
        end
        rx_symb(r,c) *= exp(-j*phi_(r,c));
      end

      if verbose > 2
        printf("\nrx_symb: ");
        for r=1:Nsymbrow
          printf("% 4.3f ", angle(rx_symb(r,c)))
        end
        printf("\nindexes: ");
        for r=1:Nsymbrow
          st = Npilotsframe+1+floor((r-1)/Ns) - floor(Np/2) + 1;
          en = st + Np - 1;
          printf("%2d,%2d  ", st,en)
        end
        printf("\npilots : ");
        for p=1:3*Npilotsframe
          printf("% 4.3f ", angle(rx_pilot_buf(p,c)));
        end 
        printf("\n\n");
      end
    end 
    
    % de-spread
            
    for r=1:Nsymbrow
      for c=Nc+1:Nc:Nchip*Nc
        rx_symb(r,1:Nc) = rx_symb(r,1:Nc) + rx_symb(r,c:c+Nc-1);
        amp_(r,1:Nc)    = amp_(r,1:Nc) + amp_(r,c:c+Nc-1);
      end
    end
           
    % demodulate stage 2

    rx_symb_linear = zeros(1,Nsymb);
    amp_linear = zeros(1,Nsymb);
    rx_bits = zeros(1, framesize);
    for c=1:Nc
      for r=1:Nsymbrow
        i = (c-1)*Nsymbrow + r;
        rx_symb_linear(i) = rx_symb(r,c);
        amp_linear(i) = amp_(r,c);
        rx_bits((2*(i-1)+1):(2*i)) = qpsk_demod(rx_symb(r,c));
      end
    end
endfunction


function sim_out = ber_test(sim_in)
    sim_in = symbol_rate_init(sim_in);

    Fs               = sim_in.Fs;
    Rs               = sim_in.Rs;
    Ntrials          = sim_in.Ntrials;
    verbose          = sim_in.verbose;
    plot_scatter     = sim_in.plot_scatter;
    framesize        = sim_in.framesize;
    bps              = sim_in.bps;

    Esvec            = sim_in.Esvec;
    ldpc_code        = sim_in.ldpc_code;
    rate             = sim_in.ldpc_code_rate;
    code_param       = sim_in.code_param;
    tx_bits_buf      = sim_in.tx_bits_buf;
    Nsymb            = sim_in.Nsymb;
    Nsymbrow         = sim_in.Nsymbrow;
    Nsymbrowpilot    = sim_in.Nsymbrowpilot;
    Nc               = sim_in.Nc;
    Npilotsframe     = sim_in.Npilotsframe;
    Ns               = sim_in.Ns;
    Np               = sim_in.Np;
    Nchip            = sim_in.Nchip;
    modulation       = sim_in.modulation;
    pilot            = sim_in.pilot;
    prev_sym_tx      = sim_in.prev_sym_tx;
    prev_sym_rx      = sim_in.prev_sym_rx;
    rx_symb_buf      = sim_in.rx_symb_buf;
    tx_pilot_buf     = sim_in.tx_pilot_buf;
    rx_pilot_buf     = sim_in.rx_pilot_buf;

    hf_sim           = sim_in.hf_sim;
    nhfdelay         = sim_in.hf_delay_ms*Rs/1000;
    hf_mag_only      = sim_in.hf_mag_only;

    [spread spread_2ms hf_gain] = init_hf_model(Fs, Rs, Nsymbrowpilot*Ntrials);

    % Start Simulation ----------------------------------------------------------------

    for ne = 1:length(Esvec)
        EsNodB = Esvec(ne);
        EsNo = 10^(EsNodB/10);
    
        variance = 1/EsNo;
        if verbose > 1
            printf("EsNo (dB): %f EsNo: %f variance: %f\n", EsNodB, EsNo, variance);
        end
        
        Terrs = 0;  Tbits = 0;

        s_ch_tx_log      = [];
        rx_symb_log      = [];
        noise_log        = [];
        errors_log       = [];
        Nerrs_log        = [];
        phi_log          = [];
        amp_log          = [];

        ldpc_errors_log = []; ldpc_Nerrs_log = [];

        Terrsldpc = Tbitsldpc = Ferrsldpc = 0;

        % init HF channel

        hf_n = 1;

        phase_offset = 0;
        w_offset     = pi/16;

        % simulation starts here-----------------------------------
 
        for nn = 1:Ntrials+2
                  
            if ldpc_code
              tx_bits = round(rand(1,framesize*rate));                       
            else
              tx_bits = round(rand(1,framesize));                       
            end

            [s_ch tx_bits prev_sym_tx] = symbol_rate_tx(sim_in, tx_bits, code_param, prev_sym_tx);
   
            tx_bits_buf(1:framesize) = tx_bits_buf(framesize+1:2*framesize);
            tx_bits_buf(framesize+1:2*framesize) = tx_bits;

            % HF channel simulation  ------------------------------------
            
            hf_fading = ones(1,Nsymb);
            if hf_sim

                % separation between carriers.  Note this effectively
                % under samples at Rs, I dont think this matters.
                % Equivalent to doing freq shift at Fs, then
                % decimating to Rs.

                wsep = 2*pi*(1+0.5);  % e.g. 75Hz spacing at Rs=50Hz, alpha=0.5 filters

                hf_model(hf_n, :) = zeros(1,Nc*Nchip);
                
                for r=1:Nsymbrowpilot
                  for c=1:Nchip*Nc
                    time_shift = floor((c-1)*Nsymbrowpilot);
                    ahf_model = hf_gain*(spread(hf_n+time_shift) + exp(-j*c*wsep*nhfdelay)*spread_2ms(hf_n+time_shift));
                    
                    if hf_mag_only
                      s_ch(r,c) *= abs(ahf_model);
                    else
                      s_ch(r,c) *= ahf_model;
                    end
                    hf_model(hf_n, c) = ahf_model;
                  end
                  hf_n++;
                end
            end
           
            % keep a record of each tx symbol so we can check average power

            for r=1:Nsymbrow
              for c=1:Nchip*Nc
                 s_ch_tx_log = [s_ch_tx_log s_ch(r,c)];
              end
            end

            % AWGN noise and phase/freq offset channel simulation
            % 0.5 factor ensures var(noise) == variance , i.e. splits power between Re & Im

            noise = sqrt(variance*0.5)*(randn(Nsymbrowpilot,Nc*Nchip) + j*randn(Nsymbrowpilot,Nc*Nchip));
            noise_log = [noise_log noise];

            s_ch = s_ch + noise;
            
            [rx_symb rx_bits rx_symb_linear amp_linear amp_ phi_ prev_sym_rx sim_in] = symbol_rate_rx(sim_in, s_ch, prev_sym_rx);
            
            phi_log = [phi_log; phi_];
            amp_log = [amp_log; amp_];

            % Wait until we have 3 frames to do pilot assisted phase estimation

            if nn > 2 
              rx_symb_log = [rx_symb_log rx_symb_linear];

              % Measure BER

              error_positions = xor(rx_bits, tx_bits_buf(1:framesize));
              Nerrs = sum(error_positions);
              Terrs += Nerrs;
              Tbits += length(tx_bits);
              errors_log = [errors_log error_positions];
              Nerrs_log = [Nerrs_log Nerrs];

              % Optionally LDPC decode
            
              if ldpc_code
                detected_data = ldpc_dec(code_param, sim_in.max_iterations, sim_in.demod_type, sim_in.decoder_type, ...
                                         rx_symb_linear, min(100,EsNo), amp_linear);
                error_positions = xor( detected_data(1:framesize*rate), tx_bits_buf(1:framesize*rate) );
                Nerrs = sum(error_positions);
                ldpc_Nerrs_log = [ldpc_Nerrs_log Nerrs];
                ldpc_errors_log = [ldpc_errors_log error_positions];
                if Nerrs
                    Ferrsldpc++;
                end
                Terrsldpc += Nerrs;
                Tbitsldpc += framesize*rate;
              end
            end
          end
           
          TERvec(ne) = Terrs;
          BERvec(ne) = Terrs/Tbits;

            if verbose 
              av_tx_pwr = (s_ch_tx_log * s_ch_tx_log')/length(s_ch_tx_log);

              printf("EsNo (dB): %3.1f Terrs: %d BER %4.2f QPSK BER theory %4.2f av_tx_pwr: %3.2f", EsNodB, Terrs,
                       Terrs/Tbits, 0.5*erfc(sqrt(EsNo/2)), av_tx_pwr);
              if ldpc_code
                  printf("\n LDPC: Terrs: %d BER: %4.2f Ferrs: %d FER: %4.2f", 
                         Terrsldpc, Terrsldpc/Tbitsldpc, Ferrsldpc, Ferrsldpc/Ntrials);
              end
              printf("\n");
            end
    end
    
    Ebvec = Esvec - 10*log10(bps);
    sim_out.BERvec          = BERvec;
    sim_out.Ebvec           = Ebvec;
    sim_out.TERvec          = TERvec;
    sim_out.errors_log      = errors_log;
    sim_out.ldpc_errors_log = ldpc_errors_log;

    if plot_scatter
        figure(2);
        clf;
        scat = rx_symb_log .* exp(j*pi/4);
        plot(real(scat), imag(scat),'+');
        title('Scatter plot');

        if hf_sim
          figure(3);
          clf;
        
          y = 1:(hf_n-1);
          x = 1:Nc*Nchip;
          EsNodBSurface = 20*log10(abs(hf_model(y,:))) - 10*log10(variance);
          EsNodBSurface(find(EsNodBSurface < -5)) = -5;
          mesh(x,y,EsNodBSurface);
          grid
          axis([1 (Nc+1)*Nchip 1 Rs*5 -5 15])
          title('HF Channel Es/No');

          if verbose 
            [m n] = size(hf_model);
            av_hf_pwr = sum(sum(abs(hf_model(:,:)).^2))/(m*n);
            printf("average HF power: %3.2f over %d symbols\n", av_hf_pwr, m*n);
          end

          figure(5);
          clf
          subplot(211)
          [m n] = size(hf_model);
          plot(angle(hf_model(1:m,2)),'g;HF channel phase;')
          hold on;

          % set up time axis to include gaps for pilots

          [m1 n1] = size(phi_log);
          phi_x = [];
          phi_x_counter = 1;
          p = Ns;
          for r=1:m1
            if p == Ns
              phi_x_counter++;
              p = 0;
            end
            p++;
            phi_x = [phi_x phi_x_counter++];        
          end
          
          plot(phi_x, phi_log(:,2),'r+;Estimated HF channel phase;')
          ylabel('Phase (rads)');

          subplot(212)
          plot(abs(hf_model(1:m,2)))
          hold on;
          plot(phi_x, amp_log(:,2),'r+;Estimated HF channel amp;')
          hold off;
          ylabel('Amplitude');
          xlabel('Time (symbols)');
        end

        figure(4)
        clf
        subplot(211)
        stem(Nerrs_log)
        subplot(212)
        if ldpc_code
          stem(ldpc_Nerrs_log)
        end
   end

endfunction

% Gray coded QPSK modulation function

function symbol = qpsk_mod(two_bits)
    two_bits_decimal = sum(two_bits .* [2 1]); 
    switch(two_bits_decimal)
        case (0) symbol =  1;
        case (1) symbol =  j;
        case (2) symbol = -j;
        case (3) symbol = -1;
    endswitch
endfunction

% Gray coded QPSK demodulation function

function two_bits = qpsk_demod(symbol)
    if isscalar(symbol) == 0
        printf("only works with scalars\n");
        return;
    end
    bit0 = real(symbol*exp(j*pi/4)) < 0;
    bit1 = imag(symbol*exp(j*pi/4)) < 0;
    two_bits = [bit1 bit0];
endfunction

function sim_in = standard_init
  sim_in.verbose          = 1;
  sim_in.plot_scatter     = 0;

  sim_in.Esvec            = 50; 
  sim_in.Ntrials          = 30;
  sim_in.framesize        = 2;
  sim_in.Rs               = 50;

  sim_in.phase_offset     = 0;
  sim_in.w_offset         = 0;
  sim_in.phase_noise_amp  = 0;

  sim_in.hf_delay_ms      = 2;
  sim_in.hf_sim           = 0;
  sim_in.hf_mag_only      = 0;

  sim_in.Nchip            = 1;
endfunction

function test_curves

  sim_in = standard_init();

  sim_in.verbose          = 1;
  sim_in.plot_scatter     = 1;

  sim_in.Esvec            = 10; 
  sim_in.hf_sim           = 1;
  sim_in.Ntrials          = 1000;
  sim_in.Rs               = 200;
  sim_in.Np               = 4;
  sim_in.Ns               = 8;
  sim_in.Nchip            = 1;

  sim_qpsk                = ber_test(sim_in, 'qpsk');

  sim_in.hf_sim           = 0;
  sim_in.plot_scatter     = 0;
  sim_in.Esvec            = 10:20; 
  Ebvec = sim_in.Esvec - 10*log10(2);
  BER_theory = 0.5*erfc(sqrt(10.^(Ebvec/10)));

  sim_in.Np               = 0;
  sim_in.Nchip            = 1;

  sim_dqpsk               = ber_test(sim_in, 'dqpsk');
  sim_in.hf_sim           = 1;
  sim_in.hf_mag_only      = 1;
  sim_qpsk_hf_ideal       = ber_test(sim_in, 'qpsk');
  sim_in.hf_mag_only      = 0;
  sim_dqpsk_hf            = ber_test(sim_in, 'dqpsk');
  sim_in.Np               = 6;
  sim_qpsk_hf_pilot       = ber_test(sim_in, 'qpsk');
  sim_in.Nchip            = 2;
  sim_qpsk_hf_pilot_dsss  = ber_test(sim_in, 'qpsk');

  figure(1); 
  clf;
  semilogy(Ebvec, BER_theory,'r;QPSK theory;')
  hold on;
  semilogy(sim_dqpsk.Ebvec, sim_dqpsk.BERvec,'c;DQPSK AWGN;')
  semilogy(sim_qpsk_hf_ideal.Ebvec, sim_qpsk_hf_ideal.BERvec,'b;QPSK HF ideal;')
  semilogy(sim_dqpsk_hf.Ebvec, sim_dqpsk_hf.BERvec,'k;DQPSK HF;')
  semilogy(sim_qpsk_hf_pilot.Ebvec, sim_qpsk_hf_pilot.BERvec,'r;QPSK Np=6 HF;')
  semilogy(sim_qpsk_hf_pilot_dsss.Ebvec, sim_qpsk_hf_pilot_dsss.BERvec,'g;QPSK Np=6 Nchip=2 HF;')
  hold off;

  xlabel('Eb/N0')
  ylabel('BER')
  grid("minor")
  axis([min(Ebvec) max(Ebvec) 1E-3 1])
endfunction

function test_single

  sim_in = standard_init();

  sim_in.verbose          = 1;
  sim_in.plot_scatter     = 1;

  sim_in.framesize        = 576;
  sim_in.Nc               = 9;
  sim_in.Rs               = 50;
  sim_in.Ns               = 4;
  sim_in.Np               = 2;
  sim_in.Nchip            = 1;
  sim_in.ldpc_code_rate   = 0.5;
  sim_in.ldpc_code        = 1;

  sim_in.Ntrials          = 20;
  sim_in.Esvec            = 7; 
  sim_in.hf_sim           = 1;
  sim_in.hf_mag_only      = 0;
  sim_in.modulation       = 'qpsk';

  sim_qpsk_hf             = ber_test(sim_in);

  fep=fopen("errors_450.bin","wb"); fwrite(fep, sim_qpsk_hf.ldpc_errors_log, "short"); fclose(fep);
endfunction

% Rate Fs test funcs -----------------------------------------------------------

function rate_Fs_tx(tx_filename)
  sim_in = standard_init();

  sim_in.verbose          = 1;
  sim_in.plot_scatter     = 1;

  sim_in.framesize        = 576;
  sim_in.Nc               = 9;
  sim_in.Rs               = 50;
  sim_in.Ns               = 4;
  sim_in.Np               = 2;
  sim_in.Nchip            = 1;
  sim_in.ldpc_code_rate   = 0.5;
  sim_in.ldpc_code        = 1;

  sim_in.Ntrials          = 20;
  sim_in.Esvec            = 7; 
  sim_in.hf_sim           = 1;
  sim_in.hf_mag_only      = 0;
  sim_in.modulation       = 'qpsk';

  sim_in = symbol_rate_init(sim_in);

  prev_sym_tx             = sim_in.prev_sym_tx;
  code_param              = sim_in.code_param;
  tx_bits_buf             = sim_in.tx_bits_buf;
  framesize               = sim_in.framesize;
  rate                    = sim_in.ldpc_code_rate;
  Ntrials                 = sim_in.Ntrials;
  Rs                      = sim_in.Rs;
  Fs                      = sim_in.Fs;
  Nc                      = sim_in.Nc;

  M = Fs/Rs;

  EsNodB = sim_in.Esvec(1);
  EsNo = 10^(EsNodB/10);
 
  rx_symb_log = []; av_tx_pwr = [];

  rn_coeff = gen_rn_coeffs(0.5, 1/Fs, Rs, 6, M);
  tx_symb_buf = [];

  tx_bits = round(rand(1,framesize*rate));                       

  for nn=1:Ntrials+2

    [tx_symb tx_bits_out prev_sym_tx] = symbol_rate_tx(sim_in, tx_bits, code_param, prev_sym_tx);
    tx_bits_buf(1:framesize) = tx_bits_buf(framesize+1:2*framesize);
    tx_bits_buf(framesize+1:2*framesize) = tx_bits_out;
    tx_symb_buf = [tx_symb_buf; tx_symb];
  end
 
  % zero pad and tx filter

  [m n] = size(tx_symb_buf);
  zp = [];
  for i=1:m
    zrow = M*tx_symb_buf(i,:);
    zp = [zp; zrow; zeros(M-1,Nc)];
  end

  for c=1:Nc
    tx_filt(:,c) = filter(rn_coeff, 1, zp(:,c));
  end

  % upconvert to real IF and save to disk

  [m n] = size(tx_filt);
  tx_fdm = zeros(1,m);
  Fc = 1500;
  for c=1:Nc
    freq(c) = exp(j*2*pi*(Fc - c*Rs*1.5)/Fs);
  end
  phase_tx = ones(1,Nc);

  for c=1:Nc
    for i=1:m
      phase_tx(c) = phase_tx(c) * freq(c);
      tx_fdm(i) = tx_fdm(i) + tx_filt(i,c)*phase_tx(c);
    end
  end

  Ascale = 2000;
  figure(1);
  clf;
  plot(Ascale*real(tx_fdm))

  ftx=fopen(tx_filename,"wb"); fwrite(ftx, Ascale*real(tx_fdm), "short"); fclose(ftx);

endfunction


function rate_Fs_rx(rx_filename)
  sim_in = standard_init();

  sim_in.verbose          = 1;
  sim_in.plot_scatter     = 1;

  sim_in.framesize        = 576;
  sim_in.Nc               = 9;
  sim_in.Rs               = 50;
  sim_in.Ns               = 4;
  sim_in.Np               = 4;
  sim_in.Nchip            = 1;
  sim_in.ldpc_code_rate   = 0.5;
  sim_in.ldpc_code        = 1;

  sim_in.Ntrials          = 10;
  sim_in.Esvec            = 40; 
  sim_in.hf_sim           = 1;
  sim_in.hf_mag_only      = 0;
  sim_in.modulation       = 'qpsk';

  sim_in = symbol_rate_init(sim_in);

  prev_sym_tx             = sim_in.prev_sym_tx;
  prev_sym_rx             = sim_in.prev_sym_rx;
  code_param              = sim_in.code_param;
  tx_bits_buf             = sim_in.tx_bits_buf;
  framesize               = sim_in.framesize;
  rate                    = sim_in.ldpc_code_rate;
  Ntrials                 = sim_in.Ntrials;
  Rs                      = sim_in.Rs;
  Fs                      = sim_in.Fs;
  Nc                      = sim_in.Nc;
  Nsymbrowpilot           = sim_in.Nsymbrowpilot;
  pilot                   = sim_in.pilot;
  Ns                      = sim_in.Ns;
  Npilotsframe            = sim_in.Npilotsframe;

  M = Fs/Rs;

  EsNodB = sim_in.Esvec(1);
  EsNo = 10^(EsNodB/10);
 
  phi_log = []; amp_log = [];
  rx_symb_log = []; av_tx_pwr = [];
  Terrs = Tbits = 0;
  errors_log = []; Nerrs_log = []; 
  ldpc_Nerrs_log = []; ldpc_errors_log = [];
  Ferrsldpc = Terrsldpc = Tbitsldpc = 0;

  rn_coeff = gen_rn_coeffs(0.5, 1/Fs, Rs, 6, M);

  tx_bits = round(rand(1,framesize*rate));                       

  % read from disk

  Ascale = 2000;
  frx=fopen(rx_filename,"rb"); rx_fdm = fread(frx, "short")/Ascale; fclose(frx);

  rx_fdm=sqrt(2)*rx_fdm(1:48000);
  figure(2)
  plot(rx_fdm);

  % freq offset estimation

  f_max = test_freq_off_est(rx_filename, 16000);
  f_max = 0;
  printf("Downconverting...\n");

  [m n] = size(rx_fdm);
  rx_symb = zeros(m,Nc);
  Fc = 1500;
  for c=1:Nc
    freq(c) = exp(-j*2*pi*(-f_max + Fc - c*Rs*1.5)/Fs);
  end
  phase_rx = ones(1,Nc);
  rx_bb = zeros(m,Nc);

  for c=1:Nc
    for i=1:m
      phase_rx(c) = phase_rx(c) * freq(c);
      rx_bb(i,c) = rx_fdm(i)*phase_rx(c);
    end
  end

  sim_ch = 0;
  if sim_ch

    % freq offset

    foff = 0;
    woff = exp(j*2*pi*foff/Fs);
    phase_off = pi/2;
    for i=1:m
      for c=1:Nc
        rx_bb(i,c) = rx_bb(i,c)*phase_off;
      end
      phase_off = phase_off*woff;
    end
     
    % AWGN noise and phase/freq offset channel simulation
    % 0.5 factor ensures var(noise) == variance , i.e. splits power between Re & Im

    EsNodB = sim_in.Esvec;
    EsNo = 10^(EsNodB/10);
    variance = M/EsNo;
    [m n] = size(rx_bb);
    noise = sqrt(variance*0.5)*(randn(m,n) + j*randn(m,n));
    rx_bb = rx_bb + noise;
  end

  printf("Filtering...\n");
  for c=1:Nc
    rx_filt(:,c) = filter(rn_coeff, 1, rx_bb(:,c));
  end

  % Fine timing estimation and decimation to symbol rate Rs. Break rx
  % signal into ft=800 sample blocks for.  If clock offset is 1000ppm,
  % that's one more/less sample over Ft samples at Fs=8000 Hz.

  printf("Fine timing estimation....\n");
  ft = 1600;
  [nsam m] = size(rx_filt);
  rx_symb_buf = []; rx_timing_log = [];
  
  for st=1:ft:floor(nsam/ft - 1)*ft
    % fine timing and decimation

    env = zeros(ft,1);
    for c=1:Nc
      env = env + abs(rx_filt(st:st+ft-1,c));
    end

    % The envelope has a frequency component at the symbol rate.  The
    % phase of this frequency component indicates the timing.  So work out
    % single DFT at frequency 2*pi/M

    x = exp(-j*2*pi*(0:ft-1)/M) * env;
  
    norm_rx_timing = angle(x)/(2*pi);
    %norm_rx_timing = -0.4;
    rx_timing = -floor(norm_rx_timing*M+0.5) + M;
    rx_timing_log = [rx_timing_log norm_rx_timing];

    % printf("%d %d\n", st+rx_timing, st+rx_timing+ft-1);
    rx_symb_buf = [rx_symb_buf; rx_filt(st+rx_timing:M:st+rx_timing+ft-1,:)];
  end
  
  figure(1)
  clf;
  plot(rx_timing_log)
  axis([1 length(rx_timing_log) -0.5 0.5 ])
  title('fine timing')
  
  % Coarse timing estimation (frame sync). Use pilots to estimate
  % coarse timing (frame sync) from just first two frames over a grid
  % of possible postions.  This is a "one shot" algorithm and doesn't
  % try to resync if it's lost.  Hopefully OK for initial tests.
  
  printf("Coarse timing...\n");
  
  printf("Symbol rate demodulation....\n");
  phase_off = 1;
  Ntrials = floor((nsam/M)/Nsymbrowpilot) - 2;
  max_s = 6;
  for nn=1:Ntrials

    if nn == 1
      max_corr = 0;
      max_s    = 1;
      for s=1:Nsymbrowpilot
        st = s+(nn-1)*Nsymbrowpilot;
        e = 0;
        for i=1:Nc
          e += rx_symb_buf(st:Ns+1:st+Nsymbrowpilot-1,c)' * rx_symb_buf(st:Ns+1:st+Nsymbrowpilot-1,c);
        end
        corr = 0;
        for i=1:Nc
          corr += rx_symb_buf(st:Ns+1:st+Nsymbrowpilot-1,c)' * pilot(:,c);
        end
        corr_log(s) = abs(corr)/abs(e);
        if abs(corr)/abs(e) > max_corr
          max_corr = abs(corr)/abs(e);
          max_s    = s;
        end
      end

      printf("max_s: %d\n", max_s);
      figure(6);
      plot(corr_log)
    end

    s_ch = rx_symb_buf((nn-1)*Nsymbrowpilot+max_s:nn*Nsymbrowpilot+max_s-1,:);
    [rx_symb rx_bits rx_symb_linear amp_linear amp_ phi_ prev_sym_rx sim_in] = symbol_rate_rx(sim_in, s_ch, prev_sym_rx);
        
    rx_symb_log = [rx_symb_log rx_symb_linear];
    phi_log = [phi_log; phi_];
    amp_log = [amp_log; amp_];

    if nn > 1

      % Measure BER

      error_positions = xor(rx_bits(1:framesize*rate), tx_bits(1:framesize*rate));
      Nerrs = sum(error_positions);
      Terrs += Nerrs;
      Tbits += framesize*rate;
      errors_log = [errors_log error_positions];
      Nerrs_log = [Nerrs_log Nerrs];

      % LDPC decode
            
      detected_data = ldpc_dec(code_param, sim_in.max_iterations, sim_in.demod_type, sim_in.decoder_type, ...
                               rx_symb_linear, min(100,12), amp_linear);
      error_positions = xor(detected_data(1:framesize*rate), tx_bits(1:framesize*rate) );
      Nerrs = sum(error_positions);
      ldpc_Nerrs_log = [ldpc_Nerrs_log Nerrs];
      ldpc_errors_log = [ldpc_errors_log error_positions];
      if Nerrs
        Ferrsldpc++;
      end
      Terrsldpc += Nerrs;
      Tbitsldpc += framesize*rate;
    end
  end

  printf("EsNo (dB): %3.1f Terrs: %d BER %4.2f QPSK BER theory %4.2f av_tx_pwr: %3.2f", EsNodB, Terrs,
         Terrs/Tbits, 0.5*erfc(sqrt(EsNo/2)), av_tx_pwr);
  printf("\n LDPC: Terrs: %d BER: %4.2f Ferrs: %d FER: %4.2f\n", 
         Terrsldpc, Terrsldpc/Tbitsldpc, Ferrsldpc, Ferrsldpc/Ntrials);
 
  figure(3);
  clf;
  scat = rx_symb_log .* exp(j*pi/4);
  plot(real(scat), imag(scat),'+');
  title('Scatter plot');
        
  figure(4)
  clf
  subplot(211)
  stem(Nerrs_log)
  axis([0 Ntrials+1 0 max(Nerrs_log)+1])
  title('Uncoded Errors/Frame');
  subplot(212)
  stem(ldpc_Nerrs_log)
  axis([0 Ntrials+1 0 max(ldpc_Nerrs_log)+1])
  title('Coded Errors/Frame');

  figure(5)
  clf
  [m1 n1] = size(phi_log);
  phi_x = [];
  phi_x_counter = 1;
  p = Ns;
  for r=1:m1
    if p == Ns
      phi_x_counter++;
      p = 0;
    end
    p++;
    phi_x = [phi_x phi_x_counter++];        
  end
          
  subplot(211)
  plot(phi_x, phi_log(:,1),'r+;Estimated HF channel phase;')
  ylabel('Phase (rads)');

  subplot(212)
  plot(phi_x, amp_log(:,1),'r+;Estimated HF channel amp;')
  ylabel('Amplitude');
  xlabel('Time (symbols)');

  fep=fopen("errors_450.bin","wb"); fwrite(fep, ldpc_errors_log, "short"); fclose(fep);

endfunction

% ideas: cld estimate timing with freq offset and decimate to save cpu load
%        fft to do cross correlation

function f_max = test_freq_off_est(rx_filename, offset, n)
  fpilot = fopen("tx_zero.raw","rb"); tx_pilot = fread(fpilot, "short"); fclose(fpilot);
  frx=fopen(rx_filename,"rb"); rx_fdm = fread(frx, "short"); fclose(frx);

  Fs = 8000;
  nc = 1800;  % portion we wish to correlate over (first 2 rows on pilots)
 
  rx_fdm = rx_fdm(offset:length(rx_fdm));

  % downconvert to complex baseband to remove images

  f = 1000;
  foff_rect    = exp(j*2*pi*f*(1:2*n)/Fs);
  tx_pilot_bb  = tx_pilot(1:n) .* foff_rect(1:n)';
  rx_fdm_bb    = rx_fdm(offset:offset+2*n-1) .* foff_rect';

  % remove -2000 Hz image

  b = fir1(50, 1000/Fs);
  tx_pilot_bb_lpf = filter(b,1,tx_pilot_bb);
  rx_fdm_bb_lpf   = filter(b,1,rx_fdm_bb);

  % decimate by M

  M = 4;
  tx_pilot_bb_lpf = tx_pilot_bb_lpf(1:M:length(tx_pilot_bb_lpf));
  rx_fdm_bb_lpf   = rx_fdm_bb_lpf(1:M:length(rx_fdm_bb_lpf));
  n /= M;
  nc /= M;

  figure(1)
  subplot(211)
  plot(real(tx_pilot_bb_lpf(1:nc)))
  subplot(212)
  plot(imag(tx_pilot_bb_lpf(1:nc)))

  % correlate over a range of frequency offsets and delays

  c_max = 0;
  f_n = 1;
  f_range = -75:2.5:75;
  c_log=zeros(n, length(f_range));

  for f=f_range
    foff_rect = exp(j*2*pi*(f*M)*(1:nc)/Fs);
    for s=1:n
      
      c = abs(tx_pilot_bb_lpf(1:nc)' * (rx_fdm_bb_lpf(s:s+nc-1) .* foff_rect'));
      c_log(s,f_n) = c;
      if c > c_max
        c_max = c;
        f_max = f;
        s_max = s;
      end
    end
    f_n++;
    printf("f: %f c_max: %f f_max: %f s_max: %d\n", f, c_max, f_max, s_max);
  end

  figure(2);
  y = f_range;
  x = s_max-25:min(s_max+25, n);
  mesh(y,x, c_log(x,:));
  grid
  
endfunction


% Start simulations ---------------------------------------

more off;
%test_curves();
%test_single();
%rate_Fs_tx("tx_zero.raw");
%rate_Fs_rx("tx.wav")
%rate_Fs_rx("tx_ccir_poor_-3dB.wav")
test_freq_off_est("tx_ccir_poor_0dB_-25Hz.wav",1,5*6400)
