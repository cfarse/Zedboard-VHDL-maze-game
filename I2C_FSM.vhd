library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_protocol is
    generic(
        SYS_CLK_FREQ   : integer := 100_000_000;
        I2C_FREQ       : integer := 400_000;
        TIMEOUT_CYCLES : integer := 200_000
    );
    Port(
        clk               : in    std_logic;
        rst               : in    std_logic;
        start             : in    std_logic;
        addr              : in    std_logic_vector(6 downto 0);
        data_in           : in    std_logic_vector(7 downto 0);
        rw                : in    std_logic;
        more_data         : in    std_logic;
        restart_with_read : in    std_logic;
        tx_byte_2         : in    std_logic_vector(7 downto 0);
        tx_byte_2_en      : in    std_logic;
        scl               : inout std_logic;
        sda               : inout std_logic;
        done              : out   std_logic;
        ack_err           : out   std_logic;
        timeout_err       : out   std_logic;
        data_out          : out   std_logic_vector(7 downto 0);
        busy              : out   std_logic
    );
end i2c_protocol;

architecture Behavioral of i2c_protocol is
    type state_type is (IDLE, START_COND, REPEATED_START, TX_ADDR, ACK_ADDR,
                        TX_DATA, ACK_DATA, RX_DATA, ACK_MSTR, STOP_COND);
    signal state : state_type := IDLE;

    constant Q_DIV : integer := (SYS_CLK_FREQ + I2C_FREQ*2) / (I2C_FREQ * 4);
    signal q_cnt   : integer range 0 to Q_DIV - 1 := 0;
    signal q_tick  : std_logic := '0';
    signal phase   : integer range 0 to 3 := 0;
    signal bit_cnt : integer range 0 to 7 := 7;
    signal tx_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_reg  : std_logic_vector(7 downto 0) := (others => '0');

    signal sda_int : std_logic := '1';
    signal scl_int : std_logic := '1';
    signal ack_err_int : std_logic := '0';
    signal scl_in  : std_logic;

    signal start_d       : std_logic := '0';
    signal start_edge    : std_logic := '0';
    signal start_latched : std_logic := '0';
    signal start_pending : std_logic := '0';   -- NUOVO: latcha il fronte di start

    signal byte2_pending : std_logic := '0';

    signal timeout_cnt     : integer range 0 to TIMEOUT_CYCLES := 0;
    signal timeout_err_int : std_logic := '0';

begin
    sda <= '0' when sda_int = '0' else 'Z';
    scl <= '0' when scl_int = '0' else 'Z';
    scl_in <= scl;
    ack_err <= ack_err_int;
    timeout_err <= timeout_err_int;

    process(clk, rst)
    begin
        if rst = '1' then
            state <= IDLE;
            sda_int <= '1';
            scl_int <= '1';
            busy <= '0';
            done <= '0';
            ack_err_int <= '0';
            timeout_err_int <= '0';
            q_cnt <= 0;
            phase <= 0;
            q_tick <= '0';
            start_d <= '0';
            start_edge <= '0';
            start_latched <= '0';
            start_pending <= '0';
            byte2_pending <= '0';
            timeout_cnt <= 0;
        elsif rising_edge(clk) then
            start_edge <= start and not start_d;
            start_d <= start;

            -- NUOVO: latch del fronte di start finche' non viene consumato in IDLE
            if start_edge = '1' then
                start_pending <= '1';
            end if;

            if q_cnt = Q_DIV - 1 then
                q_cnt <= 0;
                q_tick <= '1';
            else
                q_cnt <= q_cnt + 1;
                q_tick <= '0';
            end if;

            done <= '0';

            -- Watchdog
            if state = IDLE then
                timeout_cnt <= 0;
                if start_edge = '1' then
                    timeout_err_int <= '0';
                end if;
            else
                if timeout_cnt < TIMEOUT_CYCLES then
                    timeout_cnt <= timeout_cnt + 1;
                end if;
            end if;

            if state /= IDLE and timeout_cnt >= TIMEOUT_CYCLES then
                state <= IDLE;
                sda_int <= '1';
                scl_int <= '1';
                busy <= '0';
                timeout_err_int <= '1';
                start_latched <= '0';
                byte2_pending <= '0';
            else
                if state = IDLE then
                    start_latched <= '0';
                elsif start_edge = '1' then
                    start_latched <= '1';
                elsif state = STOP_COND and phase = 3 and q_tick = '1' then
                    start_latched <= '0';
                end if;

                if q_tick = '1' then
                    if (scl_int = '1' and scl_in = '0') then
                        phase <= phase;
                    else
                        phase <= (phase + 1) mod 4;
                    end if;

                    case state is
                        when IDLE =>
                            sda_int <= '1';
                            scl_int <= '1';
                            busy <= '0';
                            ack_err_int <= '0';
                            -- MODIFICATO: consuma start_pending invece di start_edge
                            if start_pending = '1' then
                                start_pending <= '0';
                                busy <= '1';
                                tx_reg <= addr & rw;
                                byte2_pending <= tx_byte_2_en;
                                state <= START_COND;
                                phase <= 0;
                            end if;

                        when START_COND =>
                            busy <= '1';
                            if phase = 0 then
                                sda_int <= '1'; scl_int <= '1';
                            elsif phase = 1 then
                                sda_int <= '0'; scl_int <= '1';
                            elsif phase = 2 then
                                sda_int <= '0'; scl_int <= '1';
                            elsif phase = 3 then
                                sda_int <= '0'; scl_int <= '0';
                                state <= TX_ADDR;
                                bit_cnt <= 7;
                            end if;

                        when REPEATED_START =>
                            if phase = 0 then
                                sda_int <= '1'; scl_int <= '1';
                            elsif phase = 1 then
                                sda_int <= '0'; scl_int <= '1';
                            elsif phase = 2 then
                                scl_int <= '0';
                            elsif phase = 3 then
                                tx_reg <= addr & '1';
                                bit_cnt <= 7;
                                state <= TX_ADDR;
                            end if;

                        when TX_ADDR =>
                            if phase = 0 then
                                sda_int <= tx_reg(bit_cnt);
                                scl_int <= '0';
                            elsif phase = 1 or phase = 2 then
                                scl_int <= '1';
                            elsif phase = 3 then
                                scl_int <= '0';
                                if bit_cnt = 0 then
                                    state <= ACK_ADDR;
                                else
                                    bit_cnt <= bit_cnt - 1;
                                end if;
                            end if;

                        when ACK_ADDR =>
                            if phase = 0 then
                                sda_int <= '1';
                                scl_int <= '0';
                            elsif phase = 1 then
                                scl_int <= '1';
                            elsif phase = 2 then
                                scl_int <= '1';
                                if sda = '1' then
                                    ack_err_int <= '1';
                                end if;
                            elsif phase = 3 then
                                scl_int <= '0';
                                if tx_reg(0) = '0' then
                                    state <= TX_DATA;
                                    tx_reg <= data_in;
                                    bit_cnt <= 7;
                                else
                                    state <= RX_DATA;
                                    bit_cnt <= 7;
                                end if;
                            end if;

                        when TX_DATA =>
                            if phase = 0 then
                                sda_int <= tx_reg(bit_cnt);
                                scl_int <= '0';
                            elsif phase = 1 or phase = 2 then
                                scl_int <= '1';
                            elsif phase = 3 then
                                scl_int <= '0';
                                if bit_cnt = 0 then
                                    state <= ACK_DATA;
                                else
                                    bit_cnt <= bit_cnt - 1;
                                end if;
                            end if;

                        when ACK_DATA =>
                            if phase = 0 then
                                sda_int <= '1';
                                scl_int <= '0';
                            elsif phase = 1 then
                                scl_int <= '1';
                            elsif phase = 2 then
                                scl_int <= '1';
                                if sda = '1' then
                                    ack_err_int <= '1';
                                end if;
                            elsif phase = 3 then
                                scl_int <= '0';
                                if byte2_pending = '1' then
                                    byte2_pending <= '0';
                                    tx_reg  <= tx_byte_2;
                                    bit_cnt <= 7;
                                    state   <= TX_DATA;
                                else
                                    done <= '1';
                                    if restart_with_read = '1' then
                                        state <= REPEATED_START;
                                    elsif start_latched = '1' then
                                        state <= TX_DATA;
                                        tx_reg <= data_in;
                                        bit_cnt <= 7;
                                        start_pending <= '0';
                                    else
                                        state <= STOP_COND;
                                    end if;
                                end if;
                            end if;

                        when RX_DATA =>
                            if phase = 0 then
                                sda_int <= '1';
                                scl_int <= '0';
                            elsif phase = 1 then
                                scl_int <= '1';
                            elsif phase = 2 then
                                scl_int <= '1';
                                rx_reg(bit_cnt) <= sda;
                            elsif phase = 3 then
                                scl_int <= '0';
                                if bit_cnt = 0 then
                                    state <= ACK_MSTR;
                                    data_out <= rx_reg;
                                else
                                    bit_cnt <= bit_cnt - 1;
                                end if;
                            end if;

                        when ACK_MSTR =>
                            if phase = 0 then
                                sda_int <= not more_data;
                                scl_int <= '0';
                            elsif phase = 1 or phase = 2 then
                                scl_int <= '1';
                            elsif phase = 3 then
                                scl_int <= '0';
                                done <= '1';
                                if more_data = '1' then
                                    state <= RX_DATA;
                                    bit_cnt <= 7;
                                else
                                    state <= STOP_COND;
                                end if;
                            end if;

                        when STOP_COND =>
                            if phase = 0 then
                                sda_int <= '0'; scl_int <= '0';
                            elsif phase = 1 then
                                sda_int <= '0'; scl_int <= '1';
                            elsif phase = 2 then
                                sda_int <= '1'; scl_int <= '1';
                            elsif phase = 3 then
                                busy <= '0';
                                state <= IDLE;
                            end if;
                    end case;
                end if;
            end if;
        end if;
    end process;
end Behavioral;
