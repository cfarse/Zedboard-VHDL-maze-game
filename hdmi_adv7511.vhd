library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library UNISIM;
use UNISIM.VComponents.all;

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
        -- Uscite verso l'ADV7511
        hdmi_clk     : out std_logic;
        hdmi_de      : out std_logic;
        hdmi_hsync   : out std_logic;
        hdmi_vsync   : out std_logic;
        hdmi_data    : out std_logic_vector(15 downto 0);
        -- Bus I2C per la configurazione dell'ADV7511
        hdmi_scl     : inout std_logic;
        hdmi_sda     : inout std_logic;
        hdmi_hpd     : in  std_logic;
        -- Debug
        video_on_out : out std_logic;
        pixel_x_out  : out integer range 0 to 639;
        pixel_y_out  : out integer range 0 to 479;
        -- NUOVO: clock pixel esposto (post-BUFG) per il dominio di rendering
        clk_pixel_out : out std_logic
    );
end entity;

architecture rtl of hdmi_adv7511 is

    constant H_TOTAL : integer := H_VISIBLE + H_FRONT + H_SYNC + H_BACK; -- 800
    constant V_TOTAL : integer := V_VISIBLE + V_FRONT + V_SYNC + V_BACK; -- 525

    -- Clock e reset interni
    signal clk_pixel_mmcm : std_logic;   -- uscita MMCM (pre-BUFG)
    signal clk_pixel      : std_logic;   -- post-BUFG
    signal mmcm_locked    : std_logic;
    signal rst_int        : std_logic;
    signal clk_fb         : std_logic;

    -- Contatori video
    signal h_cnt, v_cnt : integer range 0 to 2047 := 0;
    signal hsync, vsync, de : std_logic;
    signal pixel_x, pixel_y : integer range 0 to 639;

    -- Pipeline RGB -> YCbCr 4:2:2
    signal s1_r, s1_g, s1_b   : std_logic_vector(3 downto 0) := (others => '0');
    signal s1_de, s1_hs, s1_vs : std_logic := '0';
    signal s1_px              : integer range 0 to 639 := 0;

    signal s2_r, s2_g, s2_b   : std_logic_vector(3 downto 0) := (others => '0');
    signal s2_de, s2_hs, s2_vs : std_logic := '0';
    signal s2_px              : integer range 0 to 639 := 0;

    signal y_odd_buf : std_logic_vector(7 downto 0) := (others => '0');
    signal cr_buf    : std_logic_vector(7 downto 0) := (others => '0');

    signal s3_data             : std_logic_vector(15 downto 0) := (others => '0');
    signal s3_de, s3_hs, s3_vs : std_logic := '0';

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

    signal rst_pixel_meta : std_logic := '1';
    signal rst_pixel_sync : std_logic := '1';

    type cfg_state_t is (CFG_IDLE, CFG_WAIT_POWER, CFG_SEND, CFG_WAIT_DONE, CFG_ERROR, CFG_COMPLETE);
    signal cfg_state : cfg_state_t := CFG_IDLE;
    signal cfg_idx   : integer range 0 to 33 := 0;
    signal wait_cnt  : integer range 0 to 10_000_000 := 0;

    type reg_pair_t is record
        addr  : std_logic_vector(7 downto 0);
        value : std_logic_vector(7 downto 0);
    end record;

    type cfg_array_t is array(0 to 33) of reg_pair_t;
    constant CFG_REGS : cfg_array_t := (
        (x"98", x"03"), (x"9A", x"E0"), (x"9C", x"30"), (x"9D", x"61"),
        (x"A2", x"A4"), (x"A3", x"A4"), (x"E0", x"D0"), (x"F9", x"00"),
        (x"15", x"01"),
        (x"16", x"F5"),
        (x"48", x"08"),
        (x"55", x"20"),
        (x"3C", x"40"),
        (x"3D", x"40"),
        (x"AF", x"06"),
        (x"17", x"02"),
        (x"18", x"46"),
        (x"B9", x"00"), (x"BA", x"00"), (x"BB", x"00"), (x"BC", x"00"),
        (x"BD", x"00"), (x"BE", x"00"), (x"BF", x"00"), (x"C0", x"00"), (x"C1", x"00"),
        (x"D0", x"00"), (x"D1", x"00"), (x"D2", x"00"), (x"D3", x"00"),
        (x"D4", x"00"), (x"D5", x"00"), (x"D6", x"00"),
        (x"F8", x"00")
    );

begin

    rst_int <= rst or not mmcm_locked;

    -------------------------------------------------------------------
    -- MMCM: genera clock pixel a 25.2 MHz da 100 MHz
    --   VCO = 100 MHz * 31.5 / 5 = 630 MHz
    --   CLKOUT0 = 630 MHz / 25 = 25.2 MHz
    -- CLKOUT0 va poi bufferizzato con BUFG (buona pratica per MMCM).
    -------------------------------------------------------------------
    mmcm_inst : MMCME2_BASE
        generic map(
            CLKIN1_PERIOD      => 10.0,
            CLKFBOUT_MULT_F    => 31.5,
            DIVCLK_DIVIDE      => 5,
            CLKOUT0_DIVIDE_F   => 25.0,
            CLKOUT0_PHASE      => 0.0,
            CLKOUT0_DUTY_CYCLE => 0.5,
            STARTUP_WAIT       => FALSE
        )
        port map(
            CLKIN1    => clk,
            CLKFBIN   => clk_fb,
            CLKFBOUT  => clk_fb,
            CLKFBOUTB => open,
            CLKOUT0   => clk_pixel_mmcm,
            CLKOUT0B  => open,
            CLKOUT1   => open,
            CLKOUT1B  => open,
            CLKOUT2   => open,
            CLKOUT2B  => open,
            CLKOUT3   => open,
            CLKOUT3B  => open,
            CLKOUT4   => open,
            CLKOUT5   => open,
            CLKOUT6   => open,
            LOCKED    => mmcm_locked,
            PSCLK     => '0',
            PSEN      => '0',
            PSINCDEC  => '0',
            PSDONE    => open,
            RST       => rst,
            POWERDOWN => '0'
        );

    -- BUFG esplicito: il clock pixel deve passare per un buffer globale
    u_bufg_pixel : BUFG
        port map(
            I => clk_pixel_mmcm,
            O => clk_pixel
        );

    
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            rst_pixel_meta <= rst_int;
            rst_pixel_sync <= rst_pixel_meta;
        end if;
    end process;

    -------------------------------------------------------------------
    -- Contatori orizzontale/verticale (in clk_pixel)
    -------------------------------------------------------------------
    process(clk_pixel)
    begin
        if rising_edge(clk_pixel) then
            if rst_pixel_sync = '1' then
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

    hdmi_clk      <= clk_pixel;
    clk_pixel_out <= clk_pixel;   -- NUOVO: esposto a create_maze

    -------------------------------------------------------------------
    -- Pipeline RGB 4:4:4 -> YCbCr 4:2:2 (BT.601)
    -- (invariata rispetto alla versione precedente)
    -------------------------------------------------------------------
    process(clk_pixel)
        variable r_a, g_a, b_a : unsigned(7 downto 0);
        variable r_b, g_b, b_b : unsigned(7 downto 0);
        variable sum_r, sum_g, sum_b : unsigned(9 downto 0);
        variable y_a_acc, y_b_acc   : unsigned(15 downto 0);
        variable y_a, y_b           : unsigned(7 downto 0);
        variable cb_acc, cr_acc     : integer range 0 to 262143;
        variable cb_v, cr_v         : unsigned(7 downto 0);
    begin
        if rising_edge(clk_pixel) then
            if rst_pixel_sync = '1' then
                s1_r <= (others=>'0'); s1_g <= (others=>'0'); s1_b <= (others=>'0');
                s1_de <= '0'; s1_hs <= '0'; s1_vs <= '0'; s1_px <= 0;
                s2_r <= (others=>'0'); s2_g <= (others=>'0'); s2_b <= (others=>'0');
                s2_de <= '0'; s2_hs <= '0'; s2_vs <= '0'; s2_px <= 0;
                s3_data <= (others=>'0');
                s3_de <= '0'; s3_hs <= '0'; s3_vs <= '0';
                y_odd_buf <= (others=>'0');
                cr_buf    <= (others=>'0');
                hdmi_data  <= (others=>'0');
                hdmi_de    <= '0';
                hdmi_hsync <= '0';
                hdmi_vsync <= '0';
            else
                s1_r <= pix_r; s1_g <= pix_g; s1_b <= pix_b;
                s1_de <= de;   s1_hs <= hsync; s1_vs <= vsync;
                s1_px <= pixel_x;

                s2_r <= s1_r; s2_g <= s1_g; s2_b <= s1_b;
                s2_de <= s1_de; s2_hs <= s1_hs; s2_vs <= s1_vs;
                s2_px <= s1_px;

                r_a := unsigned(s2_r & s2_r);
                g_a := unsigned(s2_g & s2_g);
                b_a := unsigned(s2_b & s2_b);
                r_b := unsigned(s1_r & s1_r);
                g_b := unsigned(s1_g & s1_g);
                b_b := unsigned(s1_b & s1_b);

                y_a_acc := resize(r_a * to_unsigned( 77, 8), 16)
                         + resize(g_a * to_unsigned(150, 8), 16)
                         + resize(b_a * to_unsigned( 29, 8), 16);
                y_a := resize(shift_right(y_a_acc, 8), 8);

                y_b_acc := resize(r_b * to_unsigned( 77, 8), 16)
                         + resize(g_b * to_unsigned(150, 8), 16)
                         + resize(b_b * to_unsigned( 29, 8), 16);
                y_b := resize(shift_right(y_b_acc, 8), 8);

                sum_r := resize(r_a, 10) + resize(r_b, 10);
                sum_g := resize(g_a, 10) + resize(g_b, 10);
                sum_b := resize(b_a, 10) + resize(b_b, 10);

                cb_acc := 65536
                        - 43  * to_integer(sum_r)
                        - 85  * to_integer(sum_g)
                        + 128 * to_integer(sum_b);
                cr_acc := 65536
                        + 128 * to_integer(sum_r)
                        - 107 * to_integer(sum_g)
                        - 21  * to_integer(sum_b);

                if cb_acc > 130815 then cb_acc := 130815; end if;
                if cb_acc < 0      then cb_acc := 0;      end if;
                if cr_acc > 130815 then cr_acc := 130815; end if;
                if cr_acc < 0      then cr_acc := 0;      end if;

                cb_v := to_unsigned(cb_acc / 512, 8);
                cr_v := to_unsigned(cr_acc / 512, 8);

                if s2_px mod 2 = 0 then
                    s3_data   <= std_logic_vector(y_a) & std_logic_vector(cb_v);
                    y_odd_buf <= std_logic_vector(y_b);
                    cr_buf    <= std_logic_vector(cr_v);
                else
                    s3_data <= y_odd_buf & cr_buf;
                end if;

                s3_de <= s2_de;
                s3_hs <= s2_hs;
                s3_vs <= s2_vs;

                hdmi_data  <= s3_data;
                hdmi_de    <= s3_de;
                hdmi_hsync <= s3_hs;
                hdmi_vsync <= s3_vs;
            end if;
        end if;
    end process;

    video_on_out <= de;
    pixel_x_out  <= pixel_x;
    pixel_y_out  <= pixel_y;

    -------------------------------------------------------------------
    -- Configurazione ADV7511 via I2C (invariata)
    -------------------------------------------------------------------
    i2c_cfg_inst : entity work.i2c_protocol
        generic map(
            SYS_CLK_FREQ   => 100_000_000,
            I2C_FREQ       => 100_000,
            TIMEOUT_CYCLES => 500_000
        )
        port map(
            clk => clk, rst => rst,
            start => i2c_start, addr => "0111001",
            data_in => i2c_data_in, rw => i2c_rw,
            more_data => i2c_more, restart_with_read => i2c_restart,
            tx_byte_2 => i2c_tx_byte_2, tx_byte_2_en => i2c_tx_byte_2_en,
            scl => hdmi_scl, sda => hdmi_sda,
            done => i2c_done, ack_err => i2c_ack_err, timeout_err => i2c_timeout_err,
            data_out => i2c_data_out, busy => i2c_busy
        );

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cfg_state <= CFG_IDLE;
                cfg_idx   <= 0;
                wait_cnt  <= 0;
                i2c_start <= '0';
                i2c_tx_byte_2_en <= '0';
                done_seen <= '0';
            else
                case cfg_state is
                    when CFG_IDLE =>
                        if hdmi_hpd = '1' then
                            cfg_state <= CFG_WAIT_POWER;
                            wait_cnt <= 0;
                        end if;
                    when CFG_WAIT_POWER =>
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
                        done_seen <= '0';
                        cfg_state <= CFG_WAIT_DONE;
                    when CFG_WAIT_DONE =>
                        if i2c_done = '1' then
                            done_seen <= '1';
                            i2c_start <= '0';
                            i2c_tx_byte_2_en <= '0';
                        end if;
                        if done_seen = '1' and i2c_busy = '0' then
                            if i2c_ack_err = '1' or i2c_timeout_err = '1' then
                                cfg_state <= CFG_ERROR;
                            elsif cfg_idx = 33 then
                                cfg_state <= CFG_COMPLETE;
                            else
                                cfg_idx <= cfg_idx + 1;
                                cfg_state <= CFG_SEND;
                            end if;
                            done_seen <= '0';
                        end if;
                    when CFG_ERROR =>
                        cfg_state <= CFG_IDLE;
                    when CFG_COMPLETE =>
                        null;
                end case;
            end if;
        end if;
    end process;

end architecture;
