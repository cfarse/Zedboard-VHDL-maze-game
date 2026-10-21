library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library UNISIM;
use UNISIM.VComponents.all;

--============================================================================
-- Controller HDMI per ZedBoard (ADV7511) - Interfaccia Parallela
-- Risoluzione: 640x480 @ 60 Hz
-- Pixel clock: 25.2 MHz (generato da MMCM)
-- L'ADV7511 riceve RGB parallelo e gestisce internamente la codifica TMDS.
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
        -- Uscite verso l'ADV7511 (interfaccia parallela)
        hdmi_clk     : out std_logic;                     -- Pixel clock
        hdmi_de      : out std_logic;                     -- Data Enable
        hdmi_hsync   : out std_logic;                     -- Sincronismo orizzontale
        hdmi_vsync   : out std_logic;                     -- Sincronismo verticale
        hdmi_data    : out std_logic_vector(15 downto 0); -- Dati RGB a 16 bit
        -- Bus I2C per la configurazione dell'ADV7511
        hdmi_scl     : inout std_logic;
        hdmi_sda     : inout std_logic;
        hdmi_hpd     : in  std_logic;
        -- Debug
        video_on_out : out std_logic;
        pixel_x_out  : out integer range 0 to 639;
        pixel_y_out  : out integer range 0 to 479
    );
end entity;

architecture rtl of hdmi_adv7511 is

    constant H_TOTAL : integer := H_VISIBLE + H_FRONT + H_SYNC + H_BACK; -- 800
    constant V_TOTAL : integer := V_VISIBLE + V_FRONT + V_SYNC + V_BACK; -- 525

    -- Clock e reset interni
    signal clk_pixel   : std_logic;
    signal mmcm_locked : std_logic;
    signal rst_int     : std_logic;
    signal clk_fb      : std_logic;

    -- Contatori video
    signal h_cnt, v_cnt : integer range 0 to 2047 := 0;
    signal hsync, vsync, de : std_logic;
    signal pixel_x, pixel_y : integer range 0 to 639;

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
    signal done_seen        : std_logic := '0';

    -- FSM configurazione
    type cfg_state_t is (CFG_IDLE, CFG_WAIT_POWER, CFG_SEND, CFG_WAIT_DONE, CFG_ERROR, CFG_COMPLETE);
    signal cfg_state : cfg_state_t := CFG_IDLE;
    signal cfg_idx   : integer range 0 to 31 := 0; -- Indice per la lista di registri
    signal wait_cnt  : integer range 0 to 10_000_000 := 0;

    -- Registri di configurazione ADV7511 per RGB 4:4:4, 640x480 @ 60Hz
    -- Basati sulla Programming Guide e su configurazioni di riferimento funzionanti.
    type reg_pair_t is record
        addr  : std_logic_vector(7 downto 0);
        value : std_logic_vector(7 downto 0);
    end record;

    type cfg_array_t is array(0 to 31) of reg_pair_t;
    constant CFG_REGS : cfg_array_t := (
        -- Registri fissi raccomandati
        (x"98", x"03"), (x"9A", x"E0"), (x"9C", x"30"), (x"9D", x"61"),
        (x"A2", x"A4"), (x"A3", x"A4"), (x"E0", x"D0"), (x"F9", x"00"),
        -- Formato input: RGB 4:4:4, 12-bit
        (x"15", x"25"),  -- Input ID: RGB 4:4:4, 12-bit (secondo registro 0x15[3:0]=0101)
        (x"F5", x"14"),  -- Output format: YCbCr 4:2:2, 10-bit, Style 2, RGB input
        -- Timing 640x480 (VIC 1)
        (x"3C", x"40"),  -- VIC[7:0]
        (x"3D", x"40"),  -- VIC[15:8]
        -- Abilita modalità HDMI e disabilita HDCP
        (x"AF", x"04"),
        -- Altri registri di configurazione video
        (x"17", x"02"),  -- Aspect ratio
        (x"18", x"46"),  -- CSC disabled
        -- Disabilita audio (registri da 0xB9 a 0xC1)
        (x"B9", x"00"), (x"BA", x"00"), (x"BB", x"00"), (x"BC", x"00"),
        (x"BD", x"00"), (x"BE", x"00"), (x"BF", x"00"), (x"C0", x"00"), (x"C1", x"00"),
        (x"D0", x"00"), (x"D1", x"00"), (x"D2", x"00"), (x"D3", x"00"),
        (x"D4", x"00"), (x"D5", x"00"), (x"D6", x"00"),
        (x"F8", x"00")   -- Registro finale
    );

begin

    -------------------------------------------------------------------
    -- Reset interno
    -------------------------------------------------------------------
    rst_int <= rst or not mmcm_locked;

    -------------------------------------------------------------------
    -- MMCM: genera clock pixel a 25.2 MHz da 100 MHz
    -- VCO = 100 MHz * 31.5 / 5 = 630 MHz
    -- CLKOUT0 = 630 MHz / 25 = 25.2 MHz
    -------------------------------------------------------------------
    mmcm_inst : MMCME2_BASE
        generic map(
            CLKIN1_PERIOD      => 10.0,    -- 100 MHz
            CLKFBOUT_MULT_F    => 31.5,    -- VCO = 630 MHz
            DIVCLK_DIVIDE      => 5,
            CLKOUT0_DIVIDE_F   => 25.0,    -- 25.2 MHz
            CLKOUT0_PHASE      => 0.0,
            CLKOUT0_DUTY_CYCLE => 0.5,
            STARTUP_WAIT       => FALSE
        )
        port map(
            CLKIN1   => clk,
            CLKFBIN  => clk_fb,
            CLKFBOUT => clk_fb,
            CLKFBOUTB => open,
            CLKOUT0  => clk_pixel,
            CLKOUT0B => open,
            CLKOUT1  => open,
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
    -- Contatori orizzontale/verticale
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

    -------------------------------------------------------------------
    -- Uscite verso l'ADV7511
    -------------------------------------------------------------------
    hdmi_clk   <= clk_pixel;
    hdmi_de    <= de;
    hdmi_hsync <= hsync;
    hdmi_vsync <= vsync;
    -- Espande i 12 bit RGB (4:4:4) a 16 bit per l'ADV7511.
    -- I 4 bit meno significativi vengono posti a zero.
    hdmi_data  <= "0000" & pix_r & pix_g & pix_b;

    video_on_out <= de;
    pixel_x_out  <= pixel_x;
    pixel_y_out  <= pixel_y;

    -------------------------------------------------------------------
    -- Configurazione ADV7511 via I2C
    -------------------------------------------------------------------
    i2c_cfg_inst : entity work.i2c_protocol
        generic map(
            SYS_CLK_FREQ   => 100_000_000,
            I2C_FREQ       => 100_000,
            TIMEOUT_CYCLES => 500_000
        )
        port map(
            clk => clk, rst => rst,
            start => i2c_start, addr => "0111001",  -- 0x39 (ADV7511)
            data_in => i2c_data_in, rw => i2c_rw,
            more_data => i2c_more, restart_with_read => i2c_restart,
            tx_byte_2 => i2c_tx_byte_2, tx_byte_2_en => i2c_tx_byte_2_en,
            scl => hdmi_scl, sda => hdmi_sda,
            done => i2c_done, ack_err => i2c_ack_err, timeout_err => i2c_timeout_err,
            data_out => i2c_data_out, busy => i2c_busy
        );

    -------------------------------------------------------------------
    -- FSM per la configurazione dei registri ADV7511
    -- CORRETTO: attende i2c_busy='0' prima di procedere con il registro successivo
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
            else
                case cfg_state is
                    when CFG_IDLE =>
                        if hdmi_hpd = '1' then
                            cfg_state <= CFG_WAIT_POWER;
                            wait_cnt <= 0;
                        end if;

                    when CFG_WAIT_POWER =>
                        if wait_cnt = 1_000_000 then -- ~10 ms
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
                        done_seen <= '0';
                        cfg_state <= CFG_WAIT_DONE;

                    when CFG_WAIT_DONE =>
                        if i2c_done = '1' then
                            done_seen <= '1';
                            i2c_start <= '0';
                            i2c_tx_byte_2_en <= '0';
                        end if;
                        -- Attende che il bus I2C sia completamente libero
                        if done_seen = '1' and i2c_busy = '0' then
                            if i2c_ack_err = '1' or i2c_timeout_err = '1' then
                                cfg_state <= CFG_ERROR;
                            elsif cfg_idx = 31 then -- Ultimo indice della lista
                                cfg_state <= CFG_COMPLETE;
                            else
                                cfg_idx <= cfg_idx + 1;
                                cfg_state <= CFG_SEND;
                            end if;
                            done_seen <= '0';
                        end if;

                    when CFG_ERROR =>
                        -- In caso di errore, riprova la configurazione
                        cfg_state <= CFG_IDLE;

                    when CFG_COMPLETE =>
                        -- Configurazione completata
                end case;
            end if;
        end if;
    end process;

end architecture;
