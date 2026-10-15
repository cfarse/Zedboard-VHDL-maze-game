library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mpu6050_driver is
    Port(
        clk        : in  std_logic;
        rst        : in  std_logic;
        start_read : in  std_logic;
        scl        : inout std_logic;
        sda        : inout std_logic;
        gyro_x     : out signed(15 downto 0);
        gyro_y     : out signed(15 downto 0);
        gyro_z     : out signed(15 downto 0);
        acc_x      : out signed(15 downto 0);
        acc_y      : out signed(15 downto 0);
        acc_z      : out signed(15 downto 0);
        temp       : out signed(15 downto 0);
        busy       : out std_logic;
        error_flag : out std_logic
    );
end mpu6050_driver;

architecture Behavioral of mpu6050_driver is

    signal i2c_start             : std_logic := '0';
    signal i2c_rw                : std_logic := '0';
    signal i2c_data_in           : std_logic_vector(7 downto 0) := (others => '0');
    signal i2c_more              : std_logic := '0';
    signal i2c_done              : std_logic;
    signal i2c_ack_err           : std_logic;
    signal i2c_timeout_err       : std_logic;
    signal i2c_timeout_err_d     : std_logic := '0';
    signal i2c_timeout_err_p     : std_logic := '0';
    signal i2c_data_out          : std_logic_vector(7 downto 0);
    signal i2c_busy              : std_logic;
    signal i2c_restart_with_read : std_logic := '0';
    signal i2c_tx_byte_2         : std_logic_vector(7 downto 0) := (others => '0');
    signal i2c_tx_byte_2_en      : std_logic := '0';

    type state_type is (WAKEUP, WAKEUP_WAIT, IDLE, WR_WAIT_DONE,
                        RD_LOOP, DONE_STATE, ERR_STATE);
    signal state : state_type := WAKEUP;

    signal byte_counter : integer range 0 to 14 := 0;
    signal buffer_data  : std_logic_vector(111 downto 0) := (others => '0');

begin

    i2c_inst : entity work.i2c_protocol
        port map(
            clk               => clk,
            rst               => rst,
            start             => i2c_start,
            addr              => "1101000",
            data_in           => i2c_data_in,
            rw                => i2c_rw,
            more_data         => i2c_more,
            restart_with_read => i2c_restart_with_read,
            tx_byte_2         => i2c_tx_byte_2,
            tx_byte_2_en      => i2c_tx_byte_2_en,
            scl               => scl,
            sda               => sda,
            done              => i2c_done,
            ack_err           => i2c_ack_err,
            timeout_err       => i2c_timeout_err,
            data_out          => i2c_data_out,
            busy              => i2c_busy
        );

    process(clk, rst)
    begin
        if rst = '1' then
            state <= WAKEUP;
            i2c_start <= '0';
            i2c_tx_byte_2_en <= '0';
            busy <= '0';
            error_flag <= '0';
            byte_counter <= 0;
            i2c_restart_with_read <= '0';
            i2c_timeout_err_d <= '0';
            i2c_timeout_err_p <= '0';
            acc_x <= (others=>'0'); acc_y <= (others=>'0'); acc_z <= (others=>'0');
            temp <= (others=>'0');
            gyro_x <= (others=>'0'); gyro_y <= (others=>'0'); gyro_z <= (others=>'0');
        elsif rising_edge(clk) then
            -- NUOVO: rilevamento fronte di salita su timeout_err
            i2c_timeout_err_d <= i2c_timeout_err;
            i2c_timeout_err_p <= i2c_timeout_err and not i2c_timeout_err_d;

            -- MODIFICATO: monitoraggio a fronte, include WAKEUP_WAIT
            if state /= IDLE and state /= ERR_STATE
               and state /= WAKEUP
               and i2c_timeout_err_p = '1' then
                state <= ERR_STATE;
                i2c_start <= '0';
                i2c_tx_byte_2_en <= '0';
            else
                case state is

                    --=================================================
                    -- WAKEUP: scrive PWR_MGMT_1 = 0x00 (2 byte)
                    --=================================================
                    when WAKEUP =>
                        busy <= '1';
                        error_flag <= '0';
                        i2c_start        <= '1';
                        i2c_rw           <= '0';
                        i2c_data_in      <= x"6B";
                        i2c_tx_byte_2    <= x"00";
                        i2c_tx_byte_2_en <= '1';
                        i2c_more         <= '0';
                        i2c_restart_with_read <= '0';
                        state <= WAKEUP_WAIT;

                    when WAKEUP_WAIT =>
                        if i2c_done = '1' then
                            i2c_start        <= '0';
                            i2c_tx_byte_2_en <= '0';
                            if i2c_ack_err = '1' then
                                state <= ERR_STATE;
                            else
                                state <= IDLE;
                            end if;
                        end if;

                    --=================================================
                    -- IDLE: attende comando di lettura
                    --=================================================
                    when IDLE =>
                        busy <= '0';
                        i2c_restart_with_read <= '0';
                        i2c_tx_byte_2_en <= '0';
                        if start_read = '1' then
                            busy <= '1';
                            error_flag <= '0';
                            i2c_restart_with_read <= '1';
                            i2c_start    <= '1';
                            i2c_rw       <= '0';
                            i2c_data_in  <= x"3B";
                            i2c_more     <= '0';
                            state <= WR_WAIT_DONE;
                        end if;

                    when WR_WAIT_DONE =>
                        if i2c_done = '1' then
                            if i2c_ack_err = '1' then
                                state <= ERR_STATE;
                            else
                                i2c_rw   <= '1';
                                i2c_more <= '1';
                                byte_counter <= 0;
                                state <= RD_LOOP;
                            end if;
                        end if;

                    when RD_LOOP =>
                        if byte_counter < 13 then
                            i2c_more <= '1';
                        else
                            i2c_more <= '0';
                        end if;

                        if i2c_done = '1' then
                            if i2c_ack_err = '1' then
                                state <= ERR_STATE;
                            else
                                buffer_data(111 - (byte_counter * 8) downto
                                            104 - (byte_counter * 8)) <= i2c_data_out;
                                if byte_counter = 13 then
                                    i2c_start <= '0';
                                    state <= DONE_STATE;
                                else
                                    byte_counter <= byte_counter + 1;
                                end if;
                            end if;
                        end if;

                    when DONE_STATE =>
                        if i2c_busy = '0' then
                            acc_x  <= signed(buffer_data(111 downto 96));
                            acc_y  <= signed(buffer_data(95 downto 80));
                            acc_z  <= signed(buffer_data(79 downto 64));
                            temp   <= signed(buffer_data(63 downto 48));
                            gyro_x <= signed(buffer_data(47 downto 32));
                            gyro_y <= signed(buffer_data(31 downto 16));
                            gyro_z <= signed(buffer_data(15 downto 0));
                            busy <= '0';
                            i2c_restart_with_read <= '0';
                            state <= IDLE;
                        end if;

                    when ERR_STATE =>
                        error_flag <= '1';
                        i2c_start <= '0';
                        i2c_restart_with_read <= '0';
                        i2c_tx_byte_2_en <= '0';
                        if i2c_busy = '0' then
                            busy <= '0';
                            state <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;
end Behavioral;
