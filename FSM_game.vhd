library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--============================================================================
-- fsm_game : Top-Level del gioco
--
-- Contiene:
--   - FSM di gioco (IDLE / LEVEL / PLAYING / RESULT)
--   - Istanza del controller HDMI (hdmi_adv7511) -> che contiene create_maze
--   - Istanza del driver MPU6050 (bus I2C separato)
--   - Debounce per i 5 pulsanti
--   - Timer 1 Hz per il countdown
--   - Edge detection del joystick per la selezione livello
--
-- Mappatura pulsanti:
--   btn_start      : avvia/entra nel livello / conferma nei menu'
--   btn_home       : torna sempre a IDLE
--   btn_reset      : (in PLAYING) riavvia il livello corrente
--   btn_physics    : cicla il parametro fisico visualizzato
--                    POS -> VEL -> ACC -> POS  (per asse X e Y)
--   btn_colorblind : toggle modalita' daltonici
--
-- Nota: la pallina e' comandata SOLO dal tilt del controller (MPU6050).
--       Il joystick serve solo a scorrere il menu' livelli.
--============================================================================
entity fsm_game is
    generic(
        SYS_CLK_FREQ : integer := 100_000_000;   -- 100 MHz ZedBoard
        GAME_TIME    : integer := 60             -- secondi per livello
    );
    port(
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- Pulsanti grezzi (dal controller, prima del debounce)
        btn_reset_raw      : in  std_logic;
        btn_start_raw      : in  std_logic;
        btn_home_raw       : in  std_logic;
        btn_colorblind_raw : in  std_logic;
        btn_physics_raw    : in  std_logic;

        -- Joystick (solo per scorrere il menu' livelli)
        joy_left     : in  std_logic;
        joy_right    : in  std_logic;

        -- Bus I2C verso il MPU6050
        mpu_scl      : inout std_logic;
        mpu_sda      : inout std_logic;

        -- Uscite verso il connettore HDMI (ADV7511)
        hdmi_clk_p   : out std_logic;
        hdmi_clk_n   : out std_logic;
        hdmi_d_p     : out std_logic_vector(2 downto 0);
        hdmi_d_n     : out std_logic_vector(2 downto 0);
        hdmi_scl     : inout std_logic;
        hdmi_sda     : inout std_logic;
        hdmi_hpd     : in  std_logic;

        -- Debug
        dbg_state    : out std_logic_vector(1 downto 0);
        dbg_timer    : out integer range 0 to 99;
        dbg_winner   : out std_logic
    );
end entity;

architecture rtl of fsm_game is

    ------------------------------------------------------------------
    -- Stati FSM
    ------------------------------------------------------------------
    constant GS_IDLE    : std_logic_vector(1 downto 0) := "00";
    constant GS_LEVEL   : std_logic_vector(1 downto 0) := "01";
    constant GS_PLAYING : std_logic_vector(1 downto 0) := "10";
    constant GS_RESULT  : std_logic_vector(1 downto 0) := "11";

    signal state : std_logic_vector(1 downto 0) := GS_IDLE;

    ------------------------------------------------------------------
    -- Segnali pulsanti debounced
    ------------------------------------------------------------------
    signal btn_reset,      btn_reset_p      : std_logic;
    signal btn_start,      btn_start_p      : std_logic;
    signal btn_home,       btn_home_p       : std_logic;
    signal btn_colorblind, btn_colorblind_p : std_logic;
    signal btn_physics,    btn_physics_p    : std_logic;

    ------------------------------------------------------------------
    -- Stato di gioco
    ------------------------------------------------------------------
    signal level_select : std_logic_vector(1 downto 0) := "00";
    signal physics_mode : std_logic_vector(1 downto 0) := "00";
    signal colorblind   : std_logic := '0';
    signal timer_secs   : integer range 0 to 99 := GAME_TIME;
    signal ball_enable  : std_logic := '0';
    signal ball_reset   : std_logic := '0';
    signal level_won    : std_logic;
    signal winner       : std_logic := '0';

    ------------------------------------------------------------------
    -- Timer 1 Hz
    ------------------------------------------------------------------
    constant ONE_SEC_CNT : integer := SYS_CLK_FREQ;
    signal sec_cnt : integer range 0 to ONE_SEC_CNT-1 := 0;

    ------------------------------------------------------------------
    -- MPU6050
    ------------------------------------------------------------------
    signal mpu_start_read : std_logic := '0';
    signal mpu_busy       : std_logic;
    signal mpu_error      : std_logic;

    signal acc_x_s  : signed(15 downto 0);
    signal acc_y_s  : signed(15 downto 0);
    signal acc_z_s  : signed(15 downto 0);
    signal gyro_x_s : signed(15 downto 0);
    signal gyro_y_s : signed(15 downto 0);
    signal gyro_z_s : signed(15 downto 0);
    signal temp_s   : signed(15 downto 0);

    constant MPU_READ_INTERVAL : integer := SYS_CLK_FREQ / 50;
    signal mpu_cnt : integer range 0 to MPU_READ_INTERVAL := 0;

    ------------------------------------------------------------------
    -- Joystick edge detection
    ------------------------------------------------------------------
    signal joy_left_d, joy_right_d   : std_logic := '0';
    signal joy_left_p, joy_right_p   : std_logic := '0';

    ------------------------------------------------------------------
    -- Reset sincronizzato
    ------------------------------------------------------------------
    signal rst_ff   : std_logic_vector(1 downto 0) := (others => '0');
    signal rst_sync : std_logic := '0';

begin

    ------------------------------------------------------------------
    -- Sincronizzazione del reset di sistema
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            rst_ff   <= rst_ff(0) & rst;
            rst_sync <= rst_ff(1);
        end if;
    end process;

    ------------------------------------------------------------------
    -- DEBOUNCE dei 5 pulsanti
    ------------------------------------------------------------------
    u_deb_reset : entity work.Debounce
        port map(
            clk => clk, rst => rst_sync,
            btn_in => btn_reset_raw,
            btn_out => btn_reset, btn_pressed => btn_reset_p,
            btn_released => open
        );

    u_deb_start : entity work.Debounce
        port map(
            clk => clk, rst => rst_sync,
            btn_in => btn_start_raw,
            btn_out => btn_start, btn_pressed => btn_start_p,
            btn_released => open
        );

    u_deb_home : entity work.Debounce
        port map(
            clk => clk, rst => rst_sync,
            btn_in => btn_home_raw,
            btn_out => btn_home, btn_pressed => btn_home_p,
            btn_released => open
        );

    u_deb_colorblind : entity work.Debounce
        port map(
            clk => clk, rst => rst_sync,
            btn_in => btn_colorblind_raw,
            btn_out => btn_colorblind, btn_pressed => btn_colorblind_p,
            btn_released => open
        );

    u_deb_physics : entity work.Debounce
        port map(
            clk => clk, rst => rst_sync,
            btn_in => btn_physics_raw,
            btn_out => btn_physics, btn_pressed => btn_physics_p,
            btn_released => open
        );

    ------------------------------------------------------------------
    -- Edge detection del joystick
    ------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            joy_left_d  <= joy_left;
            joy_right_d <= joy_right;
            joy_left_p  <= joy_left  and not joy_left_d;
            joy_right_p <= joy_right and not joy_right_d;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Driver MPU6050 (bus I2C dedicato)
    ------------------------------------------------------------------
    u_mpu : entity work.mpu6050_driver
        port map(
            clk        => clk,
            rst        => rst_sync,
            start_read => mpu_start_read,
            scl        => mpu_scl,
            sda        => mpu_sda,
            gyro_x     => gyro_x_s,
            gyro_y     => gyro_y_s,
            gyro_z     => gyro_z_s,
            acc_x      => acc_x_s,
            acc_y      => acc_y_s,
            acc_z      => acc_z_s,
            temp       => temp_s,
            busy       => mpu_busy,
            error_flag => mpu_error
        );

    ------------------------------------------------------------------
    -- Trigger periodico di lettura del MPU (~50 Hz)
    -- Attende che il driver sia libero, poi aspetta MPU_READ_INTERVAL
    -- cicli e genera un impulso di un ciclo su mpu_start_read.
    ------------------------------------------------------------------
    process(clk, rst_sync)
    begin
        if rst_sync = '1' then
            mpu_cnt        <= 0;
            mpu_start_read <= '0';
        elsif rising_edge(clk) then
            mpu_start_read <= '0';             -- default: impulso
            if mpu_busy = '0' then
                if mpu_cnt < MPU_READ_INTERVAL then
                    mpu_cnt <= mpu_cnt + 1;
                else
                    mpu_start_read <= '1';     -- triggera una nuova lettura
                    mpu_cnt        <= 0;
                end if;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Timer 1 Hz (conta solo in PLAYING, decrementa timer_secs)
    ------------------------------------------------------------------
    process(clk, rst_sync)
    begin
        if rst_sync = '1' then
            sec_cnt    <= 0;
            timer_secs <= GAME_TIME;
        elsif rising_edge(clk) then
            if state = GS_PLAYING then
                if sec_cnt = ONE_SEC_CNT - 1 then
                    sec_cnt <= 0;
                    if timer_secs > 0 then
                        timer_secs <= timer_secs - 1;
                    end if;
                else
                    sec_cnt <= sec_cnt + 1;
                end if;
            else
                sec_cnt <= 0;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- FSM principale di gioco
    ------------------------------------------------------------------
    process(clk, rst_sync)
    begin
        if rst_sync = '1' then
            state        <= GS_IDLE;
            level_select <= "00";
            physics_mode <= "00";
            colorblind   <= '0';
            timer_secs   <= GAME_TIME;
            ball_enable  <= '0';
            ball_reset   <= '0';
            winner       <= '0';
        elsif rising_edge(clk) then

            -- Pulse di default
            ball_reset <= '0';

            -- Toggle colorblind (valido in qualunque stato)
            if btn_colorblind_p = '1' then
                colorblind <= not colorblind;
            end if;

            -- Ciclo physics_mode: POS -> VEL -> ACC -> POS
            -- (un impulso per ogni pressione del pulsante)
            if btn_physics_p = '1' then
                case physics_mode is
                    when "00"   => physics_mode <= "01";
                    when "01"   => physics_mode <= "10";
                    when others => physics_mode <= "00";
                end case;
            end if;

            case state is

                ------------------------------------------------------
                -- IDLE: schermata iniziale, attende start
                ------------------------------------------------------
                when GS_IDLE =>
                    ball_enable <= '0';
                    if btn_start_p = '1' then
                        state        <= GS_LEVEL;
                        level_select <= "00";
                    end if;

                ------------------------------------------------------
                -- LEVEL: selezione livello con joystick
                ------------------------------------------------------
                when GS_LEVEL =>
                    ball_enable <= '0';

                    -- Scorrimento circolare dei 3 livelli
                    if joy_left_p = '1' then
                        case level_select is
                            when "00"   => level_select <= "10";
                            when "01"   => level_select <= "00";
                            when others => level_select <= "01";
                        end case;
                    end if;
                    if joy_right_p = '1' then
                        case level_select is
                            when "00"   => level_select <= "01";
                            when "01"   => level_select <= "10";
                            when others => level_select <= "00";
                        end case;
                    end if;

                    -- Start: inizia il livello
                    if btn_start_p = '1' then
                        state       <= GS_PLAYING;
                        timer_secs  <= GAME_TIME;
                        ball_reset  <= '1';     -- reset posizione pallina
                        ball_enable <= '1';
                        winner      <= '0';
                    end if;

                    -- Home: torna a IDLE
                    if btn_home_p = '1' then
                        state <= GS_IDLE;
                    end if;

                ------------------------------------------------------
                -- PLAYING: gioco attivo
                ------------------------------------------------------
                when GS_PLAYING =>
                    ball_enable <= '1';

                    -- Reset: riavvia il livello corrente
                    if btn_reset_p = '1' then
                        timer_secs <= GAME_TIME;
                        ball_reset <= '1';
                    end if;

                    -- Home: torna a IDLE
                    if btn_home_p = '1' then
                        state       <= GS_IDLE;
                        ball_enable <= '0';

                    -- Vittoria: pallina raggiunge il target
                    elsif level_won = '1' then
                        winner      <= '1';
                        state       <= GS_RESULT;
                        ball_enable <= '0';

                    -- Sconfitta: timer esaurito
                    elsif timer_secs = 0 then
                        winner      <= '0';
                        state       <= GS_RESULT;
                        ball_enable <= '0';
                    end if;

                ------------------------------------------------------
                -- RESULT: YOU WIN / GAME OVER + start per IDLE
                ------------------------------------------------------
                when GS_RESULT =>
                    ball_enable <= '0';

                    if btn_start_p = '1' then
                        state <= GS_IDLE;
                    end if;
                    if btn_home_p = '1' then
                        state <= GS_IDLE;
                    end if;

                when others =>
                    state <= GS_IDLE;
            end case;
        end if;
    end process;

    ------------------------------------------------------------------
    -- Motore di gioco + controller HDMI
    ------------------------------------------------------------------
    u_maze : entity work.create_maze
        generic map(
            SYS_CLK_FREQ => SYS_CLK_FREQ,
            TILT_THRESH  => 4000
        )
        port map(
            clk          => clk,
            rst          => rst_sync,
            -- Stato di gioco
            game_state   => state,
            level_select => level_select,
            physics_mode => physics_mode,
            colorblind   => colorblind,
            ball_enable  => ball_enable,
            ball_reset   => ball_reset,
            -- Sensori (accelerometro del MPU6050)
            acc_x        => acc_x_s,
            acc_y        => acc_y_s,
            -- Timer
            timer_secs   => timer_secs,
            -- Vittoria / sconfitta (mostra YOU WIN / GAME OVER)
            winner       => winner,        -- <-- NUOVO
            level_won    => level_won,
            -- HDMI
            hdmi_clk_p   => hdmi_clk_p,
            hdmi_clk_n   => hdmi_clk_n,
            hdmi_d_p     => hdmi_d_p,
            hdmi_d_n     => hdmi_d_n,
            hdmi_scl     => hdmi_scl,
            hdmi_sda     => hdmi_sda,
            hdmi_hpd     => hdmi_hpd
        );

    ------------------------------------------------------------------
    -- Debug
    ------------------------------------------------------------------
    dbg_state  <= state;
    dbg_timer  <= timer_secs;
    dbg_winner <= winner;

end architecture;
