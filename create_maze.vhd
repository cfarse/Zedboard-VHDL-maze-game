library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--============================================================================
-- create_maze : motore di gioco (maze + fisica pallina + rendering + HUD)
--
-- LAYOUT 640x480 (nessuna sovrapposizione tra elementi):
--   y =   0.. 15 : titolo "UNGABUNGA" (centrato orizzontalmente)
--   y =  32.. 47 : timer "TIME: XX"  (centrato orizzontalmente)
--   y =  48..378 : labirinto (max 331 px, dipende dal livello)
--   y = 384..478 : riquadro parametri fisici (basso-destra, x=428..636)
--
-- CONTROLLO PALLINA:
--   acc_x / acc_y provengono dal driver MPU6050 (accelerometro).
--   Il joystick NON e' collegato a questo modulo: e' usato solo dalla FSM
--   esterna per la navigazione nei menu'.
--
-- DOMINI DI CLOCK:
--   - clk          (100 MHz) : fisica, tick, blink, FSM, parametri livello
--   - clk_pixel    ( 25.2 MHz): contatori video, rendering combinatorio,
--                              pipeline YCbCr del controller HDMI
--   Il rendering legge SOLO segnali del dominio clk_pixel (versioni _s).
--============================================================================
entity create_maze is
    generic(
        SYS_CLK_FREQ : integer := 100_000_000;
        TILT_THRESH  : integer := 4000
    );
    port(
        clk            : in    std_logic;
        rst            : in    std_logic;
        game_state     : in    std_logic_vector(1 downto 0);
        level_select   : in    std_logic_vector(1 downto 0);
        physics_mode   : in    std_logic_vector(1 downto 0);
        colorblind     : in    std_logic;
        ball_enable    : in    std_logic;
        ball_reset     : in    std_logic;
        acc_x          : in    signed(15 downto 0);
        acc_y          : in    signed(15 downto 0);
        timer_secs     : in    integer range 0 to 99;
        winner         : in    std_logic;
        level_won      : out   std_logic;
        hdmi_clk       : out   std_logic;
        hdmi_de        : out   std_logic;
        hdmi_hsync     : out   std_logic;
        hdmi_vsync     : out   std_logic;
        hdmi_data      : out   std_logic_vector(15 downto 0);
        hdmi_scl       : inout std_logic;
        hdmi_sda       : inout std_logic;
        hdmi_hpd       : in    std_logic;
        sensor_fault   : in    std_logic
    );
end entity;

architecture rtl of create_maze is

    constant GS_IDLE    : std_logic_vector(1 downto 0) := "00";
    constant GS_LEVEL   : std_logic_vector(1 downto 0) := "01";
    constant GS_PLAYING : std_logic_vector(1 downto 0) := "10";
    constant GS_RESULT  : std_logic_vector(1 downto 0) := "11";

    -- Layout
    constant HUD_TOP_H    : integer := 48;   -- fascia titolo+timer
    constant MAZE_Y_START : integer := 48;   -- inizio labirinto
    -- Riquadro parametri fisici (basso-destra, sotto il labirinto)
    constant PHY_X1 : integer := 428;
    constant PHY_X2 : integer := 636;
    constant PHY_Y1 : integer := 384;
    constant PHY_Y2 : integer := 478;

    ------------------------------------------------------------------
    -- Labirinti
    ------------------------------------------------------------------
    type maze_easy_t   is array(0 to  7) of std_logic_vector( 0 to  9);
    type maze_medium_t is array(0 to 14) of std_logic_vector( 0 to 19);
    type maze_hard_t   is array(0 to 29) of std_logic_vector( 0 to 39);

    function gen_easy return maze_easy_t is
        variable m : maze_easy_t;
    begin
        m(0) := "1111111111";
        m(1) := "1000001001";
        m(2) := "1011101011";
        m(3) := "1000101011";
        m(4) := "1010100011";
        m(5) := "1110001011";
        m(6) := "1111111111";
        m(7) := "1111111111";
        return m;
    end function;

    function gen_medium return maze_medium_t is
        variable m : maze_medium_t;
    begin
        for y in 0 to 14 loop
            for x in 0 to 19 loop
                m(y)(x) := '0';
            end loop;
        end loop;
        for x in 0 to 19 loop
            m(0)(x) := '1'; m(14)(x) := '1';
        end loop;
        for y in 0 to 14 loop
            m(y)(0) := '1'; m(y)(19) := '1';
        end loop;
        for y in 3 to 12 loop
            if y mod 3 = 0 then
                for x in 1 to 18 loop
                    if (x mod 4) /= 0 then
                        m(y)(x) := '1';
                    end if;
                end loop;
            end if;
        end loop;
        for x in 6 to 12 loop
            if x mod 6 = 0 then
                for y in 1 to 13 loop
                    if (y mod 4) /= 0 then
                        m(y)(x) := '1';
                    end if;
                end loop;
            end if;
        end loop;
        return m;
    end function;

    function gen_hard return maze_hard_t is
        variable m : maze_hard_t;
    begin
        for y in 0 to 29 loop
            for x in 0 to 39 loop
                m(y)(x) := '0';
            end loop;
        end loop;
        for x in 0 to 39 loop
            m(0)(x) := '1'; m(29)(x) := '1';
        end loop;
        for y in 0 to 29 loop
            m(y)(0) := '1'; m(y)(39) := '1';
        end loop;
        for y in 3 to 27 loop
            if y mod 3 = 0 then
                for x in 1 to 38 loop
                    if (x mod 4) /= 0 then
                        m(y)(x) := '1';
                    end if;
                end loop;
            end if;
        end loop;
        for x in 6 to 36 loop
            if x mod 6 = 0 then
                for y in 1 to 28 loop
                    if (y mod 4) /= 0 then
                        m(y)(x) := '1';
                    end if;
                end loop;
            end if;
        end loop;
        return m;
    end function;

    constant EASY_M   : maze_easy_t   := gen_easy;
    constant MEDIUM_M : maze_medium_t := gen_medium;
    constant HARD_M   : maze_hard_t   := gen_hard;

    function is_wall(px, py         : integer;
                     cols, rows     : integer;
                     cell_w, cell_h : integer;
                     level          : std_logic_vector(1 downto 0))
                     return boolean is
        variable cxi, cyi : integer;
        variable w        : std_logic := '1';
    begin
        cxi := px / cell_w;
        cyi := (py - MAZE_Y_START) / cell_h;
        if cyi >= 0 and cyi < rows and cxi >= 0 and cxi < cols then
            case level is
                when "00"   => w := EASY_M(cyi)(cxi);
                when "01"   => w := MEDIUM_M(cyi)(cxi);
                when others => w := HARD_M(cyi)(cxi);
            end case;
        end if;
        return w = '1';
    end function;
    ------------------------------------------------------------------
    -- Font 8x8
    ------------------------------------------------------------------
    type font_row_t is array(0 to 7) of std_logic_vector(7 downto 0);
    type font_t     is array(0 to 39) of font_row_t;

    constant CH_SPACE : integer := 0;
    constant CH_0     : integer := 1;
    constant CH_A     : integer := 11;
    constant CH_COLON : integer := 37;
    constant CH_DOT   : integer := 38;
    constant CH_DASH  : integer := 39;

    constant FONT : font_t := (
        (x"00",x"00",x"00",x"00",x"00",x"00",x"00",x"00"),
        (x"3C",x"66",x"6E",x"76",x"66",x"66",x"3C",x"00"),
        (x"18",x"38",x"18",x"18",x"18",x"18",x"7E",x"00"),
        (x"3C",x"66",x"06",x"0C",x"18",x"30",x"7E",x"00"),
        (x"3C",x"66",x"06",x"1C",x"06",x"66",x"3C",x"00"),
        (x"0C",x"1C",x"3C",x"6C",x"7E",x"0C",x"0C",x"00"),
        (x"7E",x"60",x"7C",x"06",x"06",x"66",x"3C",x"00"),
        (x"1C",x"30",x"60",x"7C",x"66",x"66",x"3C",x"00"),
        (x"7E",x"06",x"0C",x"18",x"30",x"30",x"30",x"00"),
        (x"3C",x"66",x"66",x"3C",x"66",x"66",x"3C",x"00"),
        (x"3C",x"66",x"66",x"3E",x"06",x"0C",x"38",x"00"),
        (x"18",x"3C",x"66",x"66",x"7E",x"66",x"66",x"00"),
        (x"7C",x"66",x"66",x"7C",x"66",x"66",x"7C",x"00"),
        (x"3C",x"66",x"60",x"60",x"60",x"66",x"3C",x"00"),
        (x"78",x"6C",x"66",x"66",x"66",x"6C",x"78",x"00"),
        (x"7E",x"60",x"60",x"7C",x"60",x"60",x"7E",x"00"),
        (x"7E",x"60",x"60",x"7C",x"60",x"60",x"60",x"00"),
        (x"3C",x"66",x"60",x"6E",x"66",x"66",x"3C",x"00"),
        (x"66",x"66",x"66",x"7E",x"66",x"66",x"66",x"00"),
        (x"3C",x"18",x"18",x"18",x"18",x"18",x"3C",x"00"),
        (x"1E",x"0C",x"0C",x"0C",x"0C",x"6C",x"38",x"00"),
        (x"66",x"6C",x"78",x"70",x"78",x"6C",x"66",x"00"),
        (x"60",x"60",x"60",x"60",x"60",x"60",x"7E",x"00"),
        (x"63",x"77",x"7F",x"6B",x"63",x"63",x"63",x"00"),
        (x"66",x"76",x"7E",x"7E",x"6E",x"66",x"66",x"00"),
        (x"3C",x"66",x"66",x"66",x"66",x"66",x"3C",x"00"),
        (x"7C",x"66",x"66",x"7C",x"60",x"60",x"60",x"00"),
        (x"3C",x"66",x"66",x"66",x"66",x"3C",x"06",x"00"),
        (x"7C",x"66",x"66",x"7C",x"6C",x"66",x"66",x"00"),
        (x"3C",x"66",x"60",x"3C",x"06",x"66",x"3C",x"00"),
        (x"7E",x"18",x"18",x"18",x"18",x"18",x"18",x"00"),
        (x"66",x"66",x"66",x"66",x"66",x"66",x"3C",x"00"),
        (x"66",x"66",x"66",x"66",x"66",x"3C",x"18",x"00"),
        (x"63",x"63",x"63",x"6B",x"7F",x"77",x"63",x"00"),
        (x"66",x"66",x"3C",x"18",x"3C",x"66",x"66",x"00"),
        (x"66",x"66",x"66",x"3C",x"18",x"18",x"18",x"00"),
        (x"7E",x"06",x"0C",x"18",x"30",x"60",x"7E",x"00"),
        (x"00",x"18",x"18",x"00",x"18",x"18",x"00",x"00"),
        (x"00",x"00",x"00",x"00",x"00",x"18",x"18",x"00"),
        (x"00",x"00",x"00",x"7E",x"00",x"00",x"00",x"00")
    );

    ------------------------------------------------------------------
    -- Video (dominio clk_pixel)
    ------------------------------------------------------------------
    signal pixel_x             : integer range 0 to 639;
    signal pixel_y             : integer range 0 to 479;
    signal video_on            : std_logic;
    signal pix_r, pix_g, pix_b : std_logic_vector(3 downto 0);

    -- Clock pixel esposto dal controller HDMI (post-BUFG)
    signal clk_pixel_int : std_logic := '0';

    signal rst_px_meta : std_logic := '1';
    signal rst_px_sync : std_logic := '1';

    ------------------------------------------------------------------
    -- Parametri per livello (dominio clk 100 MHz) - usati da fisica/vittoria
    ------------------------------------------------------------------
    signal cur_cell_w : integer range 8 to 64 := 64;
    signal cur_cell_h : integer range 8 to 60 := 41;
    signal cur_cols   : integer range 8 to 40 := 10;
    signal cur_rows   : integer range 8 to 30 := 8;
    signal ball_r     : integer range 2 to 10 := 8;

    signal target_cx : integer range 0 to 40 := 8;
    signal target_cy : integer range 0 to 30 := 1;
    signal target_px : integer range 0 to 639 := 544;
    signal target_py : integer range 0 to 479 := 109;
    signal target_r  : integer range 3 to 16 := 12;

    signal level_won_int : std_logic := '0';

    ------------------------------------------------------------------
    -- Pallina (dominio clk 100 MHz)
    ------------------------------------------------------------------
    signal ball_x  : integer range 0 to 639 := 96;
    signal ball_y  : integer range 0 to 479 := 109;
    signal ball_vx : integer range -4 to 4  := 0;
    signal ball_vy : integer range -4 to 4  := 0;
    signal ball_ax : integer range -1 to 1  := 0;
    signal ball_ay : integer range -1 to 1  := 0;
    signal v_cap   : integer range 1 to 4 := 3;

    ------------------------------------------------------------------
    -- Tick movimento 100 Hz, blink 1 Hz
    ------------------------------------------------------------------
    constant MOVE_INTERVAL  : integer := SYS_CLK_FREQ / 100;
    signal move_cnt  : integer range 0 to MOVE_INTERVAL-1 := 0;
    signal move_tick : std_logic := '0';

    constant BLINK_INTERVAL : integer := SYS_CLK_FREQ / 2;
    signal blink_cnt : integer range 0 to BLINK_INTERVAL-1 := 0;
    signal blink_on  : std_logic := '1';

    ------------------------------------------------------------------
    -- Copie sincronizzate nel dominio clk_pixel (2-FF)
    --   Tutti questi segnali sono quasi-statici rispetto a clk_pixel:
    --   cambiano al massimo ogni ~10 ms (≈ 250.000 cicli pixel).
    --   Il sincronizzatore a 2 flip-flop è ampiamente sufficiente
    --   a eliminare il rischio di metastabilità.
    ------------------------------------------------------------------
    signal game_state_s   : std_logic_vector(1 downto 0) := "00";
    signal level_select_s : std_logic_vector(1 downto 0) := "00";
    signal physics_mode_s : std_logic_vector(1 downto 0) := "00";
    signal colorblind_s   : std_logic := '0';
    signal ball_x_s       : integer range 0 to 639 := 96;
    signal ball_y_s       : integer range 0 to 479 := 109;
    signal ball_vx_s      : integer range -4 to 4 := 0;
    signal ball_vy_s      : integer range -4 to 4 := 0;
    signal ball_ax_s      : integer range -1 to 1 := 0;
    signal ball_ay_s      : integer range -1 to 1 := 0;
    signal timer_secs_s   : integer range 0 to 99 := 0;
    signal winner_s       : std_logic := '0';
    signal blink_on_s     : std_logic := '1';
    signal sensor_fault_s : std_logic := '0';
    signal level_won_s    : std_logic := '0';

    -- Geometria del livello ricalcolata in clk_pixel
    --   (evita glitch sui valori derivati come target_px/target_py)
    signal cur_cell_w_s   : integer range 8 to 64 := 64;
    signal cur_cell_h_s   : integer range 8 to 60 := 41;
    signal cur_cols_s     : integer range 8 to 40 := 10;
    signal cur_rows_s     : integer range 8 to 30 := 8;
    signal ball_r_s       : integer range 2 to 10 := 8;
    signal target_px_s    : integer range 0 to 639 := 544;
    signal target_py_s    : integer range 0 to 479 := 109;
    signal target_r_s     : integer range 3 to 16 := 12;


    --second FF
    signal game_state_meta : std_logic_vector(1 downto 0) := "00";
    signal level_select_meta : std_logic_vector(1 downto 0) := "00";
    signal physics_mode_meta : std_logic_vector(1 downto 0) := "00";
    signal colorblind_meta   : std_logic := '0';
    signal ball_x_meta      : integer range 0 to 639 := 96;
    signal ball_y_meta       : integer range 0 to 479 := 109;
    signal ball_vx_meta      : integer range -4 to 4 := 0;
    signal ball_vy_meta      : integer range -4 to 4 := 0;
    signal ball_ax_meta      : integer range -1 to 1 := 0;
    signal ball_ay_meta      : integer range -1 to 1 := 0;
    signal timer_secs_meta   : integer range 0 to 99 := 0;
    signal winner_meta       : std_logic := '0';
    signal blink_on_meta     : std_logic := '1';
    signal sensor_fault_meta : std_logic := '0';
    signal level_won_meta    : std_logic := '0';

begin

    level_won <= level_won_int;

    ------------------------------------------------------------------
    -- Controller HDMI (espone clk_pixel_out per il dominio pixel)
    ------------------------------------------------------------------
    hdmi_inst : entity work.hdmi_adv7511
        generic map(
            H_VISIBLE => 640, H_FRONT => 16, H_SYNC => 96, H_BACK => 48,
            V_VISIBLE => 480, V_FRONT => 10, V_SYNC => 2,  V_BACK => 33
        )
        port map(
            clk => clk, rst => rst,
            pix_r => pix_r, pix_g => pix_g, pix_b => pix_b,
            hdmi_clk   => hdmi_clk,
            hdmi_de    => hdmi_de,
            hdmi_hsync => hdmi_hsync,
            hdmi_vsync => hdmi_vsync,
            hdmi_data  => hdmi_data,
            hdmi_scl   => hdmi_scl,
            hdmi_sda   => hdmi_sda,
            hdmi_hpd   => hdmi_hpd,
            video_on_out  => video_on,
            pixel_x_out   => pixel_x,
            pixel_y_out   => pixel_y,
            clk_pixel_out => clk_pixel_int
        );


    process (clk_pixel_int)
    begin
        if rising_edge(clk_pixel_int) then
            rst_px_meta <= rst;
            rst_px_sync <= rst_px_meta;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Tick 100 Hz (dominio clk)
    ------------------------------------------------------------------
    process(clk, rst)
    begin
        if rst = '1' then
            move_cnt <= 0; move_tick <= '0';
        elsif rising_edge(clk) then
            if move_cnt = MOVE_INTERVAL-1 then
                move_cnt <= 0; move_tick <= '1';
            else
                move_cnt <= move_cnt + 1; move_tick <= '0';
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Blink 1 Hz (dominio clk)
    ------------------------------------------------------------------
    process(clk, rst)
    begin
        if rst = '1' then
            blink_cnt <= 0; blink_on <= '1';
        elsif rising_edge(clk) then
            if blink_cnt = BLINK_INTERVAL-1 then
                blink_cnt <= 0; blink_on <= not blink_on;
            else
                blink_cnt <= blink_cnt + 1;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Parametri per livello + target (dominio clk 100 MHz)
    --   Usati da fisica pallina e rilevamento vittoria.
    ------------------------------------------------------------------
    process(clk, rst)
    begin
        if rst = '1' then
            cur_cell_w <= 64; cur_cell_h <= 41;
            cur_cols <= 10; cur_rows <= 8; ball_r <= 8;
            target_cx <= 8;  target_cy <= 1; target_r <= 12;
        elsif rising_edge(clk) then
            case level_select is
                when "00" =>  -- EASY
                    cur_cell_w <= 64; cur_cell_h <= 41;
                    cur_cols <= 10; cur_rows <= 8; ball_r <= 8;
                    target_cx <= 8;  target_cy <= 1; target_r <= 12; v_cap <= 3;
                when "01" =>  -- MEDIUM
                    cur_cell_w <= 32; cur_cell_h <= 22;
                    cur_cols <= 20; cur_rows <= 15; ball_r <= 6;
                    target_cx <= 18; target_cy <= 1; target_r <= 8; v_cap <= 2;
                when "10" =>  -- HARD
                    cur_cell_w <= 16; cur_cell_h <= 11;
                    cur_cols <= 40; cur_rows <= 30; ball_r <= 4;
                    target_cx <= 35; target_cy <= 1; target_r <= 5; v_cap <= 1;
                when others => null;
            end case;
        end if;
    end process;

    -- Posizione target in pixel (dominio clk 100 MHz, usato da vittoria)
    target_px <= target_cx * cur_cell_w + cur_cell_w/2;
    target_py <= MAZE_Y_START + target_cy * cur_cell_h + cur_cell_h/2;

    ------------------------------------------------------------------
    -- Fisica pallina (dominio clk 100 MHz)
    ------------------------------------------------------------------
        ------------------------------------------------------------------
    -- Fisica pallina (dominio clk 100 MHz)
    --   Collisione con SLIDING lungo i muri (asse-separata):
    --     1) prova a muovere solo in X (Y fissato): se libero -> OK
    --     2) prova a muovere solo in Y (con X eventualmente aggiornato):
    --        se libero -> OK
    --   Se una direzione e' bloccata ma l'altra e' libera, la pallina
    --   scivola lungo il muro invece di fermarsi.
    --
    --   Clamp Y: usa l'altezza effettiva del labirinto
    --   (MAZE_Y_START + cur_rows*cur_cell_h - 1 - ball_r), NON lo
    --   schermo (479). Clamp X: il labirinto e' largo 640 per tutti i
    --   livelli (cur_cols*cur_cell_w = 640), quindi i limiti coincidono
    --   con quelli dello schermo.
    ------------------------------------------------------------------
    process(clk, rst)
        variable ax_in, ay_in   : integer range -1 to 1;
        variable new_vx, new_vy : integer range -8 to 8;
        variable nx, ny         : integer;
        variable ball_x_new     : integer range 0 to 639;
        variable ball_y_new     : integer range 0 to 479;
        variable maze_y_max_v   : integer;
        variable hit_x, hit_y   : boolean;
    begin
        if rst = '1' then
            ball_x  <= 96; ball_y <= MAZE_Y_START + 61;
            ball_vx <= 0;  ball_vy <= 0;
            ball_ax <= 0;  ball_ay <= 0;
        elsif rising_edge(clk) then

            if ball_reset = '1' then
                case level_select is
                    when "00" =>
                        ball_x <= 1*64 + 32;                       -- 96
                        ball_y <= MAZE_Y_START + 1*41 + 20;        -- 109
                    when "01" =>
                        ball_x <= 1*32 + 16;                       -- 48
                        ball_y <= MAZE_Y_START + 1*22 + 11;        -- 81
                    when "10" =>
                        ball_x <= 1*16 + 8;                        -- 24
                        ball_y <= MAZE_Y_START + 1*11 + 5;         -- 64
                    when others => null;
                end case;
                ball_vx <= 0; ball_vy <= 0;
                ball_ax <= 0; ball_ay <= 0;

            elsif ball_enable = '1' and move_tick = '1'
                  and level_won_int = '0' then

                -- Lettura tilt dal MPU6050 (accelerometro).
                ax_in := 0; ay_in := 0;
                if to_integer(acc_x) >  TILT_THRESH then ax_in :=  1; end if;
                if to_integer(acc_x) < -TILT_THRESH then ax_in := -1; end if;
                if to_integer(acc_y) >  TILT_THRESH then ay_in :=  1; end if;
                if to_integer(acc_y) < -TILT_THRESH then ay_in := -1; end if;

                ball_ax <= ax_in;
                ball_ay <= ay_in;

                -- Accelerazione + attrito lineare
                new_vx := ball_vx + ax_in;
                new_vy := ball_vy + ay_in;

                if ax_in = 0 then
                    if new_vx > 0 then new_vx := new_vx - 1;
                    elsif new_vx < 0 then new_vx := new_vx + 1;
                    end if;
                end if;
                if ay_in = 0 then
                    if new_vy > 0 then new_vy := new_vy - 1;
                    elsif new_vy < 0 then new_vy := new_vy + 1;
                    end if;
                end if;

                if new_vx > v_cap then new_vx := v_cap;
                if new_vx < -v_cap then new_vx := -v_cap;
                if new_vy > v_cap then new_vy := v_cap;
                if new_vy < -v_cap then new_vy := -v_cap;

                ball_vx <= new_vx;
                ball_vy <= new_vy;

                -- Posizione di partenza per i test
                ball_x_new := ball_x;
                ball_y_new := ball_y;

                -- Limite Y massimo del labirinto (safety net):
                --   EASY:   48 + 8*41 - 1 - 8  = 367
                --   MEDIUM: 48 + 15*22 - 1 - 6 = 371
                --   HARD:   48 + 30*11 - 1 - 4 = 373
                maze_y_max_v := MAZE_Y_START + cur_rows*cur_cell_h
                                - 1 - ball_r;

                -- ==== FASE 1: muovi SOLO in X ====
                if new_vx /= 0 then
                    nx := ball_x + new_vx;

                    -- Clamp X (limiti schermo = limiti labirinto,
                    -- poiche' cur_cols*cur_cell_w = 640 sempre)
                    if nx < ball_r then nx := ball_r; end if;
                    if nx > 639 - ball_r then nx := 639 - ball_r; end if;

                    -- 4 angoli del bounding box a (nx, ball_y_new)
                    hit_x := is_wall(nx-ball_r, ball_y_new-ball_r,
                                     cur_cols, cur_rows, cur_cell_w, cur_cell_h,
                                     level_select) or
                             is_wall(nx+ball_r, ball_y_new-ball_r,
                                     cur_cols, cur_rows, cur_cell_w, cur_cell_h,
                                     level_select) or
                             is_wall(nx-ball_r, ball_y_new+ball_r,
                                     cur_cols, cur_rows, cur_cell_w, cur_cell_h,
                                     level_select) or
                             is_wall(nx+ball_r, ball_y_new+ball_r,
                                     cur_cols, cur_rows, cur_cell_w, cur_cell_h,
                                     level_select);

                    if not hit_x then
                        ball_x_new := nx;
                    else
                        ball_vx <= 0;   -- blocca solo la componente X
                    end if;
                end if;

                -- ==== FASE 2: muovi SOLO in Y (con X aggiornato) ====
                if new_vy /= 0 then
                    ny := ball_y + new_vy;

                    -- Clamp Y sui LIMITI DEL LABIRINTO (non 479)
                    if ny < MAZE_Y_START + ball_r then
                        ny := MAZE_Y_START + ball_r;
                    end if;
                    if ny > maze_y_max_v then
                        ny := maze_y_max_v;
                    end if;

                    -- 4 angoli del bounding box a (ball_x_new, ny)
                    hit_y := is_wall(ball_x_new-ball_r, ny-ball_r,
                                     cur_cols, cur_rows, cur_cell_w, cur_cell_h,
                                     level_select) or
                             is_wall(ball_x_new+ball_r, ny-ball_r,
                                     cur_cols, cur_rows, cur_cell_w, cur_cell_h,
                                     level_select) or
                             is_wall(ball_x_new-ball_r, ny+ball_r,
                                     cur_cols, cur_rows, cur_cell_w, cur_cell_h,
                                     level_select) or
                             is_wall(ball_x_new+ball_r, ny+ball_r,
                                     cur_cols, cur_rows, cur_cell_w, cur_cell_h,
                                     level_select);

                    if not hit_y then
                        ball_y_new := ny;
                    else
                        ball_vy <= 0;   -- blocca solo la componente Y
                    end if;
                end if;

                -- Aggiorna la posizione finale
                ball_x <= ball_x_new;
                ball_y <= ball_y_new;
            end if;
        end if;
    end process;
    ------------------------------------------------------------------
    -- Rilevamento vittoria (latch, dominio clk 100 MHz)
    ------------------------------------------------------------------
    process(clk, rst)
        variable dx, dy : integer;
    begin
        if rst = '1' then
            level_won_int <= '0';
        elsif rising_edge(clk) then
            if ball_reset = '1' or game_state /= GS_PLAYING then
                level_won_int <= '0';
            elsif level_won_int = '0' then
                dx := ball_x - target_px;
                dy := ball_y - target_py;
                if (dx*dx + dy*dy) <= ((target_r + ball_r) * (target_r + ball_r)) then
                    level_won_int <= '1';
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Sincronizzazione 100 MHz -> clk_pixel (1-FF)
    --   Reset sincrono: rst e' gia' sincronizzato a 100 MHz in fsm_game
    --   ed e' tenuto alto per migliaia di cicli pixel, quindi la
    --   reiezione in clk_pixel e' garantita.
    ------------------------------------------------------------------
    process(clk_pixel_int)
    begin
        if rising_edge(clk_pixel_int) then
            if rst_px_sync = '1' then
                game_state_meta   <= "00";
                level_select_meta <= "00";
                physics_mode_meta <= "00";
                colorblind_meta   <= '0';
                ball_x_meta       <= 96;
                ball_y_meta       <= MAZE_Y_START + 61;
                ball_vx_meta      <= 0;
                ball_vy_meta      <= 0;
                ball_ax_meta      <= 0;
                ball_ay_meta      <= 0;
                timer_secs_meta   <= 0;
                winner_meta       <= '0';
                blink_on_meta     <= '1';
                sensor_fault_meta <= '0';
                level_won_meta    <= '0';    

                game_state_s   <= "00";
                level_select_s <= "00";
                physics_mode_s <= "00";
                colorblind_s   <= '0';
                ball_x_s       <= 96;
                ball_y_s       <= MAZE_Y_START + 61;
                ball_vx_s      <= 0;
                ball_vy_s      <= 0;
                ball_ax_s      <= 0;
                ball_ay_s      <= 0;
                timer_secs_s   <= 0;
                winner_s       <= '0';
                blink_on_s     <= '1';
                sensor_fault_s <= '0';
                level_won_s    <= '0';
            else
                game_state_meta   <= game_state;
                level_select_meta <= level_select;
                physics_mode_meta <= physics_mode;
                colorblind_meta   <= colorblind;
                ball_x_meta       <= ball_x;
                ball_y_meta       <= ball_y;
                ball_vx_meta      <= ball_vx;
                ball_vy_meta      <= ball_vy;
                ball_ax_meta      <= ball_ax;
                ball_ay_meta      <= ball_ay;
                timer_secs_meta   <= timer_secs;
                winner_meta       <= winner;
                blink_on_meta     <= blink_on;
                sensor_fault_meta <= sensor_fault;
                level_won_meta    <= level_won_int;

                game_state_s   <= game_state_meta;
                level_select_s <= level_select_meta;
                physics_mode_s <= physics_mode_meta;
                colorblind_s   <= colorblind_meta;
                ball_x_s       <= ball_x_meta;
                ball_y_s       <= ball_y_meta;
                ball_vx_s      <= ball_vx_meta;
                ball_vy_s      <= ball_vy_meta;
                ball_ax_s      <= ball_ax_meta;
                ball_ay_s      <= ball_ay_meta;
                timer_secs_s   <= timer_secs_meta;
                winner_s       <= winner_meta;
                blink_on_s     <= blink_on_meta;
                sensor_fault_s <= sensor_fault_meta;
                level_won_s    <= level_won_meta;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Geometria del livello ricalcolata in clk_pixel
    --   Basata su level_select_s gia' sincronizzato, produce in modo
    --   stabile cur_cell_*_s / ball_r_s / target_*_s senza glitch.
    ------------------------------------------------------------------
    process(clk_pixel_int)
    begin
        if rising_edge(clk_pixel_int) then
            if rst_px_sync = '1' then
                cur_cell_w_s <= 64; cur_cell_h_s <= 41;
                cur_cols_s   <= 10; cur_rows_s   <= 8;
                ball_r_s     <= 8;
                target_px_s  <=  8*64 + 32;                    -- 544
                target_py_s  <= MAZE_Y_START + 1*41 + 20;      -- 109
                target_r_s   <= 12;
            else
                case level_select_s is
                    when "00" =>  -- EASY
                        cur_cell_w_s <= 64; cur_cell_h_s <= 41;
                        cur_cols_s <= 10; cur_rows_s <= 8; ball_r_s <= 8;
                        target_px_s <= 8*64 + 32;                  -- 544
                        target_py_s <= MAZE_Y_START + 1*41 + 20;   -- 109
                        target_r_s  <= 12;
                    when "01" =>  -- MEDIUM
                        cur_cell_w_s <= 32; cur_cell_h_s <= 22;
                        cur_cols_s <= 20; cur_rows_s <= 15; ball_r_s <= 6;
                        target_px_s <= 18*32 + 16;                 -- 592
                        target_py_s <= MAZE_Y_START + 1*22 + 11;   --  81
                        target_r_s  <= 8;
                    when others =>  -- HARD
                        cur_cell_w_s <= 16; cur_cell_h_s <= 11;
                        cur_cols_s <= 40; cur_rows_s <= 30; ball_r_s <= 4;
                        target_px_s <= 35*16 + 8;                  -- 568
                        target_py_s <= MAZE_Y_START + 1*11 + 5;    --  64
                        target_r_s  <= 5;
                end case;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Rendering combinatorio (dominio clk_pixel)
    --   Legge SOLO segnali del dominio clk_pixel (pixel_x, pixel_y,
    --   video_on, *_s). L'uscita viene campionata in hdmi_adv7511
    --   stage 1 sullo stesso fronte clk_pixel: nessuna CDC.
    ------------------------------------------------------------------
    render_proc : process(video_on, pixel_x, pixel_y,
                          game_state_s, level_select_s, physics_mode_s,
                          colorblind_s, blink_on_s,
                          ball_x_s, ball_y_s, ball_r_s,
                          ball_vx_s, ball_vy_s, ball_ax_s, ball_ay_s,
                          timer_secs_s, winner_s,
                          cur_cell_w_s, cur_cell_h_s, cur_cols_s, cur_rows_s,
                          target_px_s, target_py_s, target_r_s,
                          sensor_fault_s, level_won_s)

        variable ccol, crow, scol, srow : integer;
        variable ch        : integer range 0 to 39;
        variable bmp_row   : std_logic_vector(7 downto 0);
        variable pix_bit   : std_logic;
        variable use_text  : boolean;
        variable cxi, cyi  : integer;
        variable wall      : std_logic;
        variable dx, dy    : integer;
        variable is_ball   : boolean;
        variable is_target : boolean;
        variable in_phy_box : boolean;
        variable disp_x    : integer range 0 to 999;
        variable disp_y    : integer range 0 to 999;
        variable disp_sign_x : std_logic;
        variable disp_sign_y : std_logic;
    begin
        -- Sfondo di default
        if colorblind_s = '1' then
            pix_r <= "0010"; pix_g <= "0010"; pix_b <= "0010";
        else
            pix_r <= "0000"; pix_g <= "0000"; pix_b <= "0100";
        end if;

        ch       := CH_SPACE;
        use_text := false;
        in_phy_box := false;

        if video_on = '1' then
            ccol := pixel_x / 16;
            crow := pixel_y / 16;
            scol := (pixel_x mod 16) / 2;
            srow := (pixel_y mod 16) / 2;

            ----------------------------------------------------------
            -- LABIRINTO + PALLINA + TARGET
            ----------------------------------------------------------
            if pixel_y >= MAZE_Y_START and pixel_y < MAZE_Y_START + cur_rows_s * cur_cell_h_s
               and game_state_s = GS_PLAYING then

                cxi := pixel_x / cur_cell_w_s;
                cyi := (pixel_y - MAZE_Y_START) / cur_cell_h_s;

                if cyi >= 0 and cyi < cur_rows_s and cxi >= 0 and cxi < cur_cols_s then
                    case level_select_s is
                        when "00"   => wall := EASY_M(cyi)(cxi);
                        when "01"   => wall := MEDIUM_M(cyi)(cxi);
                        when others => wall := HARD_M(cyi)(cxi);
                    end case;
                    if wall = '1' then
                        if colorblind_s = '1' then
                            pix_r <= "0000"; pix_g <= "0000"; pix_b <= "1111";
                        else
                            pix_r <= "1111"; pix_g <= "1111"; pix_b <= "1111";
                        end if;
                    end if;
                end if;

                -- Pallina (sovrascrive)
                dx := pixel_x - ball_x_s;
                dy := pixel_y - ball_y_s;
                is_ball := (dx*dx + dy*dy) <= (ball_r_s*ball_r_s);

                -- Target (sovrascrive)
                dx := pixel_x - target_px_s;
                dy := pixel_y - target_py_s;
                is_target := (dx*dx + dy*dy) <= (target_r_s*target_r_s);

                if is_ball then
                    pix_r <= "1111"; pix_g <= "1111"; pix_b <= "0000";
                elsif is_target then
                    if colorblind_s = '1' then
                        pix_r <= "0000"; pix_g <= "1111"; pix_b <= "1111";
                    else
                        pix_r <= "0000"; pix_g <= "1111"; pix_b <= "0000";
                    end if;
                end if;
            end if;

            ----------------------------------------------------------
            -- RIQUADRO PARAMETRI FISICI
            ----------------------------------------------------------
            if game_state_s = GS_PLAYING and
               pixel_x >= PHY_X1 and pixel_x <= PHY_X2 and
               pixel_y >= PHY_Y1 and pixel_y <= PHY_Y2 then
                in_phy_box := true;
                if pixel_x <= PHY_X1+2 or pixel_x >= PHY_X2-2 or
                   pixel_y <= PHY_Y1+2 or pixel_y >= PHY_Y2-2 then
                    pix_r <= "1111"; pix_g <= "1111"; pix_b <= "1111";
                else
                    pix_r <= "0000"; pix_g <= "0000"; pix_b <= "1000";
                end if;
            end if;

            ----------------------------------------------------------
            -- HUD: titolo + timer
            ----------------------------------------------------------
            if pixel_y < HUD_TOP_H and game_state_s /= GS_IDLE
                                     and game_state_s /= GS_LEVEL then
                if crow = 0 then
                    case ccol is
                        when 15 => ch := CH_A + 20;  -- U
                        when 16 => ch := CH_A + 13;  -- N
                        when 17 => ch := CH_A +  6;  -- G
                        when 18 => ch := CH_A +  0;  -- A
                        when 19 => ch := CH_A +  1;  -- B
                        when 20 => ch := CH_A + 20;  -- U
                        when 21 => ch := CH_A + 13;  -- N
                        when 22 => ch := CH_A +  6;  -- G
                        when 23 => ch := CH_A +  0;  -- A
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;

                if crow = 2 then
                    case ccol is
                        when 16 => ch := CH_A + 19;  -- T
                        when 17 => ch := CH_A +  8;  -- I
                        when 18 => ch := CH_A + 12;  -- M
                        when 19 => ch := CH_A +  4;  -- E
                        when 20 => ch := CH_COLON;
                        when 21 => ch := CH_SPACE;
                        when 22 => ch := CH_0 + ((timer_secs_s/10) mod 10);
                        when 23 => ch := CH_0 + (timer_secs_s mod 10);
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
            end if;

            ----------------------------------------------------------
            -- Testo dentro il riquadro fisico
            ----------------------------------------------------------
            if in_phy_box then
                if crow = 25 then
                    case ccol is
                        when 28 =>
                            case physics_mode_s is
                                when "00"   => ch := CH_A + 15;  -- P
                                when "01"   => ch := CH_A + 21;  -- V
                                when others => ch := CH_A +  0;  -- A
                            end case;
                        when 29 =>
                            case physics_mode_s is
                                when "00"   => ch := CH_A + 14;  -- O
                                when "01"   => ch := CH_A +  4;  -- E
                                when others => ch := CH_A +  2;  -- C
                            end case;
                        when 30 =>
                            case physics_mode_s is
                                when "00"   => ch := CH_A + 18;  -- S
                                when "01"   => ch := CH_A + 11;  -- L
                                when others => ch := CH_A +  2;  -- C
                            end case;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;

                if crow = 26 then
                    case physics_mode_s is
                        when "00" => disp_x := ball_x_s;  disp_y := ball_y_s;
                                     disp_sign_x := '0'; disp_sign_y := '0';
                        when "01" =>
                            if ball_vx_s < 0 then
                                disp_x := -ball_vx_s; disp_sign_x := '1';
                            else disp_x := ball_vx_s; disp_sign_x := '0'; end if;
                            if ball_vy_s < 0 then
                                disp_y := -ball_vy_s; disp_sign_y := '1';
                            else disp_y := ball_vy_s; disp_sign_y := '0'; end if;
                        when others =>
                            if ball_ax_s < 0 then
                                disp_x := -ball_ax_s; disp_sign_x := '1';
                            else disp_x := ball_ax_s; disp_sign_x := '0'; end if;
                            if ball_ay_s < 0 then
                                disp_y := -ball_ay_s; disp_sign_y := '1';
                            else disp_y := ball_ay_s; disp_sign_y := '0'; end if;
                    end case;

                    case ccol is
                        when 28 => ch := CH_A + 23;  -- X
                        when 29 => ch := CH_COLON;
                        when 30 => if disp_sign_x='1' then ch := CH_DASH; else ch := CH_SPACE; end if;
                        when 31 => ch := CH_0 + ((disp_x/100) mod 10);
                        when 32 => ch := CH_0 + ((disp_x/10) mod 10);
                        when 33 => ch := CH_0 + (disp_x mod 10);
                        when 34 => ch := CH_A + 24;  -- Y
                        when 35 => ch := CH_COLON;
                        when 36 => if disp_sign_y='1' then ch := CH_DASH; else ch := CH_SPACE; end if;
                        when 37 => ch:= CH_0 + ((disp_y/100) mod 10);
                        when 38 => ch := CH_0 + ((disp_y/10) mod 10);
                        when 39 => ch := CH_0 + (disp_y mod 10);
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;

                if crow = 27 and level_won_s = '1' then
                    case ccol is
                        when 28 => ch := CH_A + 22;  -- W
                        when 29 => ch := CH_A +  8;  -- I
                        when 30 => ch := CH_A + 13;  -- N
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
            end if;

            ----------------------------------------------------------
            -- Schermate IDLE / LEVEL / RESULT
            ----------------------------------------------------------
            if game_state_s = GS_IDLE then
                if crow = 8 then
                    case ccol is
                        when 15 => ch := CH_A + 12; when 16 => ch := CH_A +  0;
                        when 17 => ch := CH_A + 25; when 18 => ch := CH_A +  4;
                        when 20 => ch := CH_A +  6; when 21 => ch := CH_A +  0;
                        when 22 => ch := CH_A + 12; when 23 => ch := CH_A +  4;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
                if crow = 14 and blink_on_s = '1' then
                    case ccol is
                        when 14 => ch := CH_A + 15; when 15 => ch := CH_A + 17;
                        when 16 => ch := CH_A +  4; when 17 => ch := CH_A + 18;
                        when 18 => ch := CH_A + 18; when 20 => ch := CH_A + 18;
                        when 21 => ch := CH_A + 19; when 22 => ch := CH_A +  0;
                        when 23 => ch := CH_A + 17; when 24 => ch := CH_A + 19;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
                if crow = 20 then
                    case ccol is
                        when 14 => ch := CH_A + 15; when 15 => ch := CH_A +  7;
                        when 16 => ch := CH_A + 24; when 17 => ch := CH_A + 18;
                        when 18 => ch := CH_COLON;
                        when 20 =>
                            case physics_mode_s is
                                when "00"   => ch := CH_A + 15;
                                when "01"   => ch := CH_A + 21;
                                when others => ch := CH_A +  0;
                            end case;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
            end if;

            if game_state_s = GS_LEVEL then
                if crow = 3 then
                    case ccol is
                        when 14 => ch := CH_A + 18; when 15 => ch := CH_A +  4;
                        when 16 => ch := CH_A + 11; when 17 => ch := CH_A +  4;
                        when 18 => ch := CH_A +  2; when 19 => ch := CH_A + 19;
                        when 21 => ch := CH_A + 11; when 22 => ch := CH_A +  4;
                        when 23 => ch := CH_A + 21; when 24 => ch := CH_A +  4;
                        when 25 => ch := CH_A + 11;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
                if crow = 8 then
                    case ccol is
                        when 10 => if level_select_s="00" then ch:=CH_COLON; else ch:=CH_SPACE; end if;
                        when 12 => ch := CH_A +  4; when 13 => ch := CH_A +  0;
                        when 14 => ch := CH_A + 18; when 15 => ch := CH_A + 24;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
                if crow = 12 then
                    case ccol is
                        when 10 => if level_select_s="01" then ch:=CH_COLON; else ch:=CH_SPACE; end if;
                        when 12 => ch := CH_A + 12; when 13 => ch := CH_A +  4;
                        when 14 => ch := CH_A +  3; when 15 => ch := CH_A +  8;
                        when 16 => ch := CH_A + 20; when 17 => ch := CH_A + 12;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
                if crow = 16 then
                    case ccol is
                        when 10 => if level_select_s="10" then ch:=CH_COLON; else ch:=CH_SPACE; end if;
                        when 12 => ch := CH_A +  7; when 13 => ch := CH_A +  0;
                        when 14 => ch := CH_A + 17; when 15 => ch := CH_A +  3;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
                if crow = 22 and blink_on_s = '1' then
                    case ccol is
                        when 14 => ch := CH_A + 15; when 15 => ch := CH_A + 17;
                        when 16 => ch := CH_A +  4; when 17 => ch := CH_A + 18;
                        when 18 => ch := CH_A + 18; when 20 => ch := CH_A + 18;
                        when 21 => ch := CH_A + 19; when 22 => ch := CH_A +  0;
                        when 23 => ch := CH_A + 17; when 24 => ch := CH_A + 19;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
            end if;

            if game_state_s = GS_RESULT then
                if crow = 8 then
                    if winner_s = '1' then
                        case ccol is
                            when 16 => ch := CH_A +24;
                            when 17 => ch := CH_A +14;
                            when 18 => ch := CH_A +20;
                            when 20 => ch := CH_A +22;
                            when 21 => ch := CH_A +8;
                            when 22 => ch := CH_A +13;
                            when others => ch := CH_SPACE;
                        end case;
                    else
                        case ccol is
                            when 15 => ch := CH_A +  6; when 16 => ch := CH_A +  0;
                            when 17 => ch := CH_A + 12; when 18 => ch := CH_A +  4;
                            when 20 => ch := CH_A + 14; when 21 => ch := CH_A + 21;
                            when 22 => ch := CH_A +  4; when 23 => ch := CH_A + 17;
                            when others => ch := CH_SPACE;
                        end case;
                    end if;
                    use_text := true;
                end if;
                if crow = 14 and blink_on_s = '1' then
                    case ccol is
                        when 14 => ch := CH_A + 15; when 15 => ch := CH_A + 17;
                        when 16 => ch := CH_A +  4; when 17 => ch := CH_A + 18;
                        when 18 => ch := CH_A + 18; when 20 => ch := CH_A + 18;
                        when 21 => ch := CH_A + 19; when 22 => ch := CH_A +  0;
                        when 23 => ch := CH_A + 17; when 24 => ch := CH_A + 19;
                        when others => ch := CH_SPACE;
                    end case;
                    use_text := true;
                end if;
            end if;

            ----------------------------------------------------------
            -- Banner sensor fault
            ----------------------------------------------------------
            if sensor_fault_s = '1' and video_on = '1' then
                if pixel_x >= 160 and pixel_x <= 479 and
                   pixel_y >= 200 and pixel_y <= 279 then
                    if pixel_x <= 162 or pixel_x >= 477 or
                       pixel_y <= 202 or pixel_y >= 277 then
                        pix_r <= "1111"; pix_g <= "1111"; pix_b <= "1111";
                    else
                        pix_r <= "1000"; pix_g <= "0000"; pix_b <= "0000";
                    end if;
                end if;
            end if;

            if sensor_fault_s = '1' and crow = 16 then
                case ccol is
                    when 14 => ch := CH_A + 18;  -- S
                    when 15 => ch := CH_A +  4;  -- E
                    when 16 => ch := CH_A + 13;  -- N
                    when 17 => ch := CH_A + 18;  -- S
                    when 18 => ch := CH_A + 14;  -- O
                    when 19 => ch := CH_A + 17;  -- R
                    when 20 => ch := CH_SPACE;
                    when 21 => ch := CH_A +  4;  -- E
                    when 22 => ch := CH_A + 17;  -- R
                    when 23 => ch := CH_A + 17;  -- R
                    when 24 => ch := CH_A + 14;  -- O
                    when 25 => ch := CH_A + 17;  -- R
                    when others => ch := CH_SPACE;
                end case;
                use_text := true;
            end if;

            -- Applica testo sopra tutto
            if use_text and ch /= CH_SPACE then
                bmp_row := FONT(ch, srow);
                pix_bit := bmp_row(7 - scol);
                if pix_bit = '1' then
                    if colorblind_s = '1' then
                        pix_r <= "0000"; pix_g <= "1111"; pix_b <= "0000";
                    else
                        pix_r <= "1111"; pix_g <= "1111"; pix_b <= "1111";
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture;
