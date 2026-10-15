library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library UNISIM;
use UNISIM.VComponents.all;

--============================================================================
-- Controller HDMI per ZedBoard (ADV7511)
-- Risoluzione: 640x480 @ 60 Hz
-- Pixel clock: 25.175 MHz (generato da MMCM)
-- TMDS clock: 125.875 MHz (5x pixel clock)
-- Configurazione ADV7511 via I2C (riutilizza modulo i2c_protocol)
-- Serializzazione TMDS 10:1 con OSERDESE2 width expansion
--============================================================================
entity hdmi_adv7511 is
    generic(
        H_VISIBLE : integer := 640;
        H_FRONT   : integer := 16;
        H_SYNC    : integer := 96;
        H_BACK    : integer := 48;
        V_VISIBLE : integer := 480;
        V_FRONT   : integer := 10;
        V_SYNC    : integer := 2;
        V_BACK    : integer := 33
    );
    port(
        clk          : in  std_logic;   -- 100 MHz ZedBoard
        rst          : in  std_logic;
        -- Ingresso pixel (12 bit RGB)
        pix_r        : in  std_logic_vector(3 downto 0);
        pix_g        : in  std_logic_vector(3 downto 0);
        pix_b        : in  std_logic_vector(3 downto 0);
        -- Uscite verso il connettore HDMI (J8)
        hdmi_clk_p   : out std_logic;
        hdmi_clk_n   : out std_logic;
        hdmi_d_p     : out std_logic_vector(2 downto 0);
        hdmi_d_n     : out std_logic_vector(2 downto 0);
        hdmi_scl     : inout std_logic;
        hdmi_sda     : inout std_logic;
        hdmi_hpd     : in  std_logic;
        -- Debug
        hsync_out    : out std_logic;
        vsync_out    : out std_logic;
        video_on_out : out std_logic;
        pixel_x_out  : out integer range 0 to 639;
        pixel_y_out  : out integer range 0 to 479
    );
end entity;

architecture rtl of hdmi_adv7511 is

    constant H_TOTAL : integer := H_VISIBLE + H_FRONT + H_SYNC + H_BACK;
    constant V_TOTAL : integer := V_VISIBLE + V_FRONT + V_SYNC + V_BACK;

    -- Clock e reset interni
    signal clk_pixel   : std_logic;
    signal clk_5x      : std_logic;
    signal mmcm_locked : std_logic;
    signal rst_int     : std_logic;

    -- Contatori video
    signal h_cnt, v_cnt : integer range 0 to 2047 := 0;
    signal hsync, vsync, de : std_logic;
    signal pixel_x, pixel_y : integer range 0 to 639;
    signal pix_en : std_logic := '0';

    -- TMDS encoded data
    signal tmds_red, tmds_green, tmds_blue : std_logic_vector(9 downto 0);

    -- Uscite serializzate (prima di OBUFDS)
    signal tmds_red_serial, tmds_green_serial, tmds_blue_serial : std_logic;
    signal tmds_clk_serial : std_logic;

    -- I2C configurazione
    signal cfg_done    : std_logic := '0';
    signal cfg_start   : std_logic := '1';
    signal cfg_scl     : std_logic;
    signal cfg_sda_out : std_logic;
    signal cfg_sda_in  : std_logic;
    signal cfg_sda_oe  : std_logic;

    -- Segnali per i2c_protocol
    signal i2c_start        : std_logic := '0';
    signal i2c_rw           : std_logic := '0';
    signal i2c_data_in      : std_logic_vector(7 downto 0) := (others => '0');
    signal i2c_more         : std_logic := '0';
    signal i2c_restart      : std_logic := '0';
    signal i2c_tx_byte_2    : std_logic_vector(7 downto 0) := (others => '0');
    signal i2c_tx_byte_2_en : std_logic := '0';
    signal i2c_done         : std_logic;
    signal i2c_ack_err      : std_logic;
    signal i2c_timeout_err  : std_logic;
    signal i2c_data_out     : std_logic_vector(7 downto 0);
    signal i2c_busy         : std_logic;

    -- FSM configurazione
    type cfg_state_t is (CFG_IDLE, CFG_WAIT_POWER, CFG_SEND, CFG_WAIT_DONE, CFG_ERROR, CFG_COMPLETE);
    signal cfg_state : cfg_state_t := CFG_IDLE;
    signal cfg_idx   : integer range 0 to 47 := 0;
    signal wait_cnt  : integer range 0 to 10_000_000 := 0;

    -- Registri configurazione ADV7511 per 640x480 @ 60Hz
    -- (basati sulla lista fornita, da verificare con datasheet)
    type reg_pair_t is record
        addr  : std_logic_vector(7 downto 0);
        value : std_logic_vector(7 downto 0);
    end record;

    type cfg_array_t is array(0 to 47) of reg_pair_t;
    constant CFG_REGS : cfg_array_t := (
        (x"41", x"10"),  -- Power up
        (x"98", x"03"),  -- Fixed register
        (x"9A", x"E0"),  -- Fixed register
        (x"9C", x"30"),  -- Fixed register
        (x"9D", x"61"),  -- Fixed register
        (x"A2", x"A4"),  -- Fixed register
        (x"A3", x"A4"),  -- Fixed register
        (x"E0", x"D0"),  -- Fixed register
        (x"F9", x"00"),  -- Fixed register
        (x"15", x"00"),  -- 4:4:4 RGB
        (x"16", x"3C"),  -- 4:4:4 RGB
        (x"17", x"02"),  -- Aspect ratio
        (x"18", x"46"),  -- CSC disabled
        (x"3C", x"40"),  -- VIC 640x480
        (x"3D", x"40"),  -- VIC 640x480
        (x"AF", x"04"),  -- HDMI mode
        (x"B9", x"00"),  -- Audio off
        (x"BA", x"00"),
        (x"BB", x"00"),
        (x"BC", x"00"),
        (x"BD", x"00"),
        (x"BE", x"00"),
        (x"BF", x"00"),
        (x"C0", x"00"),
        (x"C1", x"00"),
        (x"C2", x"00"),
        (x"C3", x"00"),
        (x"C4", x"00"),
        (x"C5", x"00"),
        (x"C6", x"00"),
        (x"C7", x"00"),
        (x"C8", x"00"),
        (x"C9", x"00"),
        (x"CA", x"00"),
        (x"CB", x"00"),
        (x"CC", x"00"),
        (x"CD", x"00"),
        (x"CE", x"00"),
        (x"CF", x"00"),
        (x"D0", x"00"),
        (x"D1", x"00"),
        (x"D2", x"00"),
        (x"D3", x"00"),
        (x"D4", x"00"),
        (x"D5", x"00"),
        (x"D6", x"00"),
        (x"F8", x"00"),
        (x"F9", x"00")
    );

begin

    -------------------------------------------------------------------
    -- Reset interno sincronizzato con MMCM locked
    -------------------------------------------------------------------
    rst_int <= rst or not mmcm_locked;

    -------------------------------------------------------------------
    -- MMCM: genera clock pixel (25.175 MHz) e clock 5x (125.875 MHz)
    -- Input: 100 MHz
    -- VCO: 100 MHz * 25.175 = 2517.5 MHz? Troppo alto.
    -- Meglio: 100 MHz * 10 = 1000 MHz, poi dividere.
    -- Per 25.175 MHz: 1000 / 39.72... non intero.
    -- Usiamo 100 MHz * 20 = 2000 MHz? No, VCO max 1600 MHz.
    -- Approccio: 100 MHz * 25 = 2500 MHz (troppo alto).
    -- In realtà, per 640x480, possiamo usare 25.2 MHz (100 * 63 / 250 = 25.2).
    -- Pixel clock: 25.2 MHz, TMDS clock: 126 MHz.
    -- MMCM: CLKOUT0 = 25.2 MHz, CLKOUT1 = 126 MHz.
    -- VCO = 126 * 8 = 1008 MHz (ok, VCO range 600-1600).
    -- CLKOUT0 = VCO / 40 = 25.2 MHz.
    -- CLKOUT1 = VCO / 8 = 126 MHz.
    -- M = 10.08? No, M deve essere intero.
    -- Usiamo VCO = 100 * 10.08 = 1008 MHz? M=10.08 non intero.
    -- Meglio: VCO = 100 * 10 = 1000 MHz, CLKOUT0 = 1000/40 = 25 MHz (accettabile).
    -- CLKOUT1 = 1000/8 = 125 MHz.
    -- Per 640x480, 25 MHz è accettabile (standard VGA).
    -------------------------------------------------------------------
    mmcm_inst : MMCME2_BASE
        generic map(
            CLKIN1_PERIOD => 10.0,  -- 100 MHz
            CLKFBOUT_MULT_F => 10.0,
            DIVCLK_DIVIDE => 1,
            CLKOUT0_DIVIDE_F => 40.0,  -- 25 MHz
            CLKOUT1_DIVIDE => 8,       -- 125 MHz
            CLKOUT0_PHASE => 0.0,
            CLKOUT1_PHASE => 0.0,
            CLKOUT0_DUTY_CYCLE => 0.5,
            CLKOUT1_DUTY_CYCLE => 0.5,
            STARTUP_WAIT => FALSE
        )
        port map(
            CLKIN1   => clk,
            CLKFBIN  => open,
            CLKFBOUT => open,
            CLKFBOUTB => open,
            CLKOUT0  => clk_pixel,
            CLKOUT0B => open,
            CLKOUT1  => clk_5x,
            CLKOUT1B => open,
            CLKOUT2  => open,
            CLKOUT2B => open,
            CLKOUT3  => open,
            CLKOUT3B => open,
            CLKOUT4  => open,
            CLKOUT5  => open,
            CLKOUT6  => open,
            LOCKED   => mmcm_locked,
            PSCLK    => '0',
            PSEN     => '0',
            PSINCDEC => '0',
            PSDONE   => open,
            RST      => rst,
            POWERDOWN => '0'
        );

    -------------------------------------------------------------------
    -- Contatori orizzontale/verticale (basati su clk_pixel)
    -------------------------------------------------------------------
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst_int = '1' then
                h_cnt <= 0;
                v_cnt <= 0;
            else
                if h_cnt = H_TOTAL-1 then
                    h_cnt <= 0;
                    if v_cnt = V_TOTAL-1 then
                        v_cnt <= 0;
                    else
                        v_cnt <= v_cnt + 1;
                    end if;
                else
                    h_cnt <= h_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    hsync <= '0' when (h_cnt >= H_VISIBLE + H_FRONT) and
                       (h_cnt <  H_VISIBLE + H_FRONT + H_SYNC) else '1';
    vsync <= '0' when (v_cnt >= V_VISIBLE + V_FRONT) and
                       (v_cnt <  V_VISIBLE + V_FRONT + V_SYNC) else '1';
    de    <= '1' when (h_cnt < H_VISIBLE) and (v_cnt < V_VISIBLE) else '0';

    pixel_x <= h_cnt when h_cnt < H_VISIBLE else 0;
    pixel_y <= v_cnt when v_cnt < V_VISIBLE else 0;

    hsync_out    <= hsync;
    vsync_out    <= vsync;
    video_on_out <= de;
    pixel_x_out  <= pixel_x;
    pixel_y_out  <= pixel_y;

    -------------------------------------------------------------------
    -- TMDS encoder (3 canali)
    -------------------------------------------------------------------
    tmds_enc_red : entity work.tmds_encoder
        port map(clk => clk_pixel, rst => rst_int, data => pix_r & "0000", de => de,
                 hsync => hsync, vsync => vsync, tmds => tmds_red);

    tmds_enc_green : entity work.tmds_encoder
        port map(clk => clk_pixel, rst => rst_int, data => pix_g & "0000", de => de,
                 hsync => hsync, vsync => vsync, tmds => tmds_green);

    tmds_enc_blue : entity work.tmds_encoder
        port map(clk => clk_pixel, rst => rst_int, data => pix_b & "0000", de => de,
                 hsync => hsync, vsync => vsync, tmds => tmds_blue);

    -------------------------------------------------------------------
    -- Serializzazione TMDS 10:1 con OSERDESE2 width expansion
    -- Per ogni canale (R, G, B): master + slave
    -------------------------------------------------------------------

    -- Canale ROSSO
    oserdes_red_master : OSERDESE2
        generic map(
            DATA_RATE_OQ => "DDR",
            DATA_RATE_TQ => "SDR",
            DATA_WIDTH => 10,
            SERDES_MODE => "MASTER",
            INIT_OQ => '0',
            SRVAL_OQ => '0',
            INIT_TQ => '0',
            SRVAL_TQ => '0',
            TRISTATE_WIDTH => 1
        )
        port map(
            OQ => tmds_red_serial,
            SHIFTOUT1 => open,
            SHIFTOUT2 => open,
            SHIFTIN1 => red_shiftout1,
            SHIFTIN2 => red_shiftout2,
            D1 => tmds_red(0),
            D2 => tmds_red(1),
            D3 => tmds_red(2),
            D4 => tmds_red(3),
            D5 => tmds_red(4),
            D6 => tmds_red(5),
            D7 => tmds_red(6),
            D8 => tmds_red(7),
            T1 => '0', T2 => '0', T3 => '0', T4 => '0',
            TQ => open,
            CLK => clk_5x,
            CLKDIV => clk_pixel,
            OCE => '1',
            RST => rst_int,
            TBYTEIN => '0',
            TBYTEOUT => open
        );

    oserdes_red_slave : OSERDESE2
        generic map(
            DATA_RATE_OQ => "DDR",
            DATA_RATE_TQ => "SDR",
            DATA_WIDTH => 10,
            SERDES_MODE => "SLAVE",
            INIT_OQ => '0',
            SRVAL_OQ => '0',
            INIT_TQ => '0',
            SRVAL_TQ => '0',
            TRISTATE_WIDTH => 1
        )
        port map(
            OQ => open,
            SHIFTOUT1 => red_shiftout1,
            SHIFTOUT2 => red_shiftout2,
            SHIFTIN1 => '0',
            SHIFTIN2 => '0',
            D1 => '0', D2 => '0',
            D3 => tmds_red(8),
            D4 => tmds_red(9),
            D5 => '0', D6 => '0', D7 => '0', D8 => '0',
            T1 => '0', T2 => '0', T3 => '0', T4 => '0',
            TQ => open,
            CLK => clk_5x,
            CLKDIV => clk_pixel,
            OCE => '1',
            RST => rst_int,
            TBYTEIN => '0',
            TBYTEOUT => open
        );

    -- Canale VERDE
    oserdes_green_master : OSERDESE2
        generic map(
            DATA_RATE_OQ => "DDR",
            DATA_RATE_TQ => "SDR",
            DATA_WIDTH => 10,
            SERDES_MODE => "MASTER",
            INIT_OQ => '0',
            SRVAL_OQ => '0',
            INIT_TQ => '0',
            SRVAL_TQ => '0',
            TRISTATE_WIDTH => 1
        )
        port map(
            OQ => tmds_green_serial,
            SHIFTOUT1 => open,
            SHIFTOUT2 => open,
            SHIFTIN1 => green_shiftout1,
            SHIFTIN2 => green_shiftout2,
            D1 => tmds_green(0),
            D2 => tmds_green(1),
            D3 => tmds_green(2),
            D4 => tmds_green(3),
            D5 => tmds_green(4),
            D6 => tmds_green(5),
            D7 => tmds_green(6),
            D8 => tmds_green(7),
            T1 => '0', T2 => '0', T3 => '0', T4 => '0',
            TQ => open,
            CLK => clk_5x,
            CLKDIV => clk_pixel,
            OCE => '1',
            RST => rst_int,
            TBYTEIN => '0',
            TBYTEOUT => open
        );

    oserdes_green_slave : OSERDESE2
        generic map(
            DATA_RATE_OQ => "DDR",
            DATA_RATE_TQ => "SDR",
            DATA_WIDTH => 10,
            SERDES_MODE => "SLAVE",
            INIT_OQ => '0',
            SRVAL_OQ => '0',
            INIT_TQ => '0',
            SRVAL_TQ => '0',
            TRISTATE_WIDTH => 1
        )
        port map(
            OQ => open,
            SHIFTOUT1 => green_shiftout1,
            SHIFTOUT2 => green_shiftout2,
            SHIFTIN1 => '0',
            SHIFTIN2 => '0',
            D1 => '0', D2 => '0',
            D3 => tmds_green(8),
            D4 => tmds_green(9),
            D5 => '0', D6 => '0', D7 => '0', D8 => '0',
            T1 => '0', T2 => '0', T3 => '0', T4 => '0',
            TQ => open,
            CLK => clk_5x,
            CLKDIV => clk_pixel,
            OCE => '1',
            RST => rst_int,
            TBYTEIN => '0',
            TBYTEOUT => open
        );

    -- Canale BLU
    oserdes_blue_master : OSERDESE2
        generic map(
            DATA_RATE_OQ => "DDR",
            DATA_RATE_TQ => "SDR",
            DATA_WIDTH => 10,
            SERDES_MODE => "MASTER",
            INIT_OQ => '0',
            SRVAL_OQ => '0',
            INIT_TQ => '0',
            SRVAL_TQ => '0',
            TRISTATE_WIDTH => 1
        )
        port map(
            OQ => tmds_blue_serial,
            SHIFTOUT1 => open,
            SHIFTOUT2 => open,
            SHIFTIN1 => blue_shiftout1,
            SHIFTIN2 => blue_shiftout2,
            D1 => tmds_blue(0),
            D2 => tmds_blue(1),
            D3 => tmds_blue(2),
            D4 => tmds_blue(3),
            D5 => tmds_blue(4),
            D6 => tmds_blue(5),
            D7 => tmds_blue(6),
            D8 => tmds_blue(7),
            T1 => '0', T2 => '0', T3 => '0', T4 => '0',
            TQ => open,
            CLK => clk_5x,
            CLKDIV => clk_pixel,
            OCE => '1',
            RST => rst_int,
            TBYTEIN => '0',
            TBYTEOUT => open
        );

    oserdes_blue_slave : OSERDESE2
        generic map(
            DATA_RATE_OQ => "DDR",
            DATA_RATE_TQ => "SDR",
            DATA_WIDTH => 10,
            SERDES_MODE => "SLAVE",
            INIT_OQ => '0',
            SRVAL_OQ => '0',
            INIT_TQ => '0',
            SRVAL_TQ => '0',
            TRISTATE_WIDTH => 1
        )
        port map(
            OQ => open,
            SHIFTOUT1 => blue_shiftout1,
            SHIFTOUT2 => blue_shiftout2,
            SHIFTIN1 => '0',
            SHIFTIN2 => '0',
            D1 => '0', D2 => '0',
            D3 => tmds_blue(8),
            D4 => tmds_blue(9),
            D5 => '0', D6 => '0', D7 => '0', D8 => '0',
            T1 => '0', T2 => '0', T3 => '0', T4 => '0',
            TQ => open,
            CLK => clk_5x,
            CLKDIV => clk_pixel,
            OCE => '1',
            RST => rst_int,
            TBYTEIN => '0',
            TBYTEOUT => open
        );

    -------------------------------------------------------------------
    -- Clock TMDS: generato con ODDR a partire da clk_5x
    -- ODDR produce un'onda a 125 MHz (commuta su entrambi i fronti)
    -------------------------------------------------------------------
    oddr_clk : ODDR
        generic map(
            DDR_CLK_EDGE => "OPPOSITE_EDGE",
            INIT => '0',
            SRTYPE => "SYNC"
        )
        port map(
            Q  => tmds_clk_serial,
            C  => clk_5x,
            CE => '1',
            D1 => '1',
            D2 => '0',
            R  => rst_int,
            S  => '0'
        );

    -------------------------------------------------------------------
    -- Buffer differenziali di uscita (OBUFDS)
    -------------------------------------------------------------------
    obufds_clk : OBUFDS
        port map(
            I  => tmds_clk_serial,
            O  => hdmi_clk_p,
            OB => hdmi_clk_n
        );

    obufds_red : OBUFDS
        port map(
            I  => tmds_red_serial,
            O  => hdmi_d_p(2),
            OB => hdmi_d_n(2)
        );

    obufds_green : OBUFDS
        port map(
            I  => tmds_green_serial,
            O  => hdmi_d_p(1),
            OB => hdmi_d_n(1)
        );

    obufds_blue : OBUFDS
        port map(
            I  => tmds_blue_serial,
            O  => hdmi_d_p(0),
            OB => hdmi_d_n(0)
        );

    -------------------------------------------------------------------
    -- Configurazione ADV7511 via I2C
    -- Istanza del modulo i2c_protocol
    -------------------------------------------------------------------
    i2c_cfg_inst : entity work.i2c_protocol
        generic map(
            SYS_CLK_FREQ   => 100_000_000,
            I2C_FREQ       => 100_000,
            TIMEOUT_CYCLES => 500_000
        )
        port map(
            clk               => clk,
            rst               => rst,
            start             => i2c_start,
            addr              => "0111001",  -- 0x39 (ADV7511)
            data_in           => i2c_data_in,
            rw                => i2c_rw,
            more_data         => i2c_more,
            restart_with_read => i2c_restart,
            tx_byte_2         => i2c_tx_byte_2,
            tx_byte_2_en      => i2c_tx_byte_2_en,
            scl               => hdmi_scl,
            sda               => hdmi_sda,
            done              => i2c_done,
            ack_err           => i2c_ack_err,
            timeout_err       => i2c_timeout_err,
            data_out          => i2c_data_out,
            busy              => i2c_busy
        );

    -------------------------------------------------------------------
    -- FSM per la configurazione dei registri ADV7511
    -------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cfg_state <= CFG_IDLE;
                cfg_idx   <= 0;
                wait_cnt  <= 0;
                i2c_start <= '0';
                i2c_tx_byte_2_en <= '0';
                cfg_done <= '0';
            else
                case cfg_state is
                    when CFG_IDLE =>
                        cfg_done <= '0';
                        if hdmi_hpd = '1' then
                            cfg_state <= CFG_WAIT_POWER;
                            wait_cnt <= 0;
                        end if;

                    when CFG_WAIT_POWER =>
                        -- Attesa power-up (es. 10 ms a 100 MHz)
                        if wait_cnt = 1_000_000 then
                            cfg_state <= CFG_SEND;
                            cfg_idx <= 0;
                        else
                            wait_cnt <= wait_cnt + 1;
                        end if;

                    when CFG_SEND =>
                        i2c_start <= '1';
                        i2c_rw <= '0';
                        i2c_data_in <= CFG_REGS(cfg_idx).addr;
                        i2c_tx_byte_2 <= CFG_REGS(cfg_idx).value;
                        i2c_tx_byte_2_en <= '1';
                        i2c_more <= '0';
                        i2c_restart <= '0';
                        cfg_state <= CFG_WAIT_DONE;

                    when CFG_WAIT_DONE =>
                        if i2c_done = '1' then
                            i2c_start <= '0';
                            i2c_tx_byte_2_en <= '0';
                            if i2c_ack_err = '1' or i2c_timeout_err = '1' then
                                cfg_state <= CFG_ERROR;
                            else
                                if cfg_idx = 47 then
                                    cfg_state <= CFG_COMPLETE;
                                else
                                    cfg_idx <= cfg_idx + 1;
                                    cfg_state <= CFG_SEND;
                                end if;
                            end if;
                        end if;

                    when CFG_ERROR =>
                        -- In caso di errore, riprova o segnala
                        cfg_state <= CFG_IDLE;

                    when CFG_COMPLETE =>
                        cfg_done <= '1';
                        -- Rimane in COMPLETE
                end case;
            end if;
        end if;
    end process;

    -- Segnali non utilizzati (per evitare warning)
    cfg_scl <= '1';
    cfg_sda_out <= '1';
    cfg_sda_oe <= '0';
    cfg_sda_in <= hdmi_sda;
    cfg_start <= '0';

end architecture;
