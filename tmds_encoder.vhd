library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--============================================================================
-- TMDS Encoder (algoritmo DVI 1.0 / HDMI)
-- Converte 8 bit dati + 2 bit controllo in 10 bit TMDS
--============================================================================
entity tmds_encoder is
    port(
        clk   : in  std_logic;
        rst   : in  std_logic;
        data  : in  std_logic_vector(7 downto 0);  -- pixel component
        de    : in  std_logic;  -- display enable
        hsync : in  std_logic;
        vsync : in  std_logic;
        tmds  : out std_logic_vector(9 downto 0)
    );
end entity;

architecture rtl of tmds_encoder is
    signal cnt : signed(4 downto 0) := (others => '0');
begin
    process(clk, rst)
        variable q_m     : std_logic_vector(8 downto 0) := (others => '0');
        variable n1_q_m  : integer := 0;
        variable n1_n0   : integer := 0;
    begin
        if rst = '1' then
            tmds <= "1101010100";
            cnt  <= (others => '0');
        elsif rising_edge(clk) then
            if de = '1' then
                -- Fase 1: minimizza le transizioni
                n1_q_m := 0;
                for i in 0 to 7 loop
                    if data(i) = '1' then
                        n1_q_m := n1_q_m + 1;
                    end if;
                end loop;

                if n1_q_m > 4 or (n1_q_m = 4 and data(0) = '0') then
                    q_m(0) := data(0);
                    for i in 1 to 7 loop
                        q_m(i) := not (data(i) xor q_m(i-1));
                    end loop;
                    q_m(8) := '0';
                else
                    q_m(0) := data(0);
                    for i in 1 to 7 loop
                        q_m(i) := (data(i) xor q_m(i-1));
                    end loop;
                    q_m(8) := '1';
                end if;

                -- Fase 2: controllo DC balance
                n1_q_m := 0;
                for i in 0 to 7 loop
                    if q_m(i) = '1' then
                        n1_q_m := n1_q_m + 1;
                    end if;
                end loop;
                n1_n0 := 8 - n1_q_m;

                if q_m(8) = '0' then
                    n1_n0 := n1_n0 + 1;
                else
                    n1_n0 := n1_n0 - 1;
                end if;

                if cnt = 0 or n1_q_m = n1_n0 then
                    if q_m(8) = '0' then
                        tmds(9) <= '0';
                        tmds(8) <= q_m(8);
                        for i in 0 to 7 loop
                            tmds(i) <= q_m(i);
                        end loop;
                    else
                        tmds(9) <= '1';
                        tmds(8) <= q_m(8);
                        for i in 0 to 7 loop
                            tmds(i) <= not q_m(i);
                        end loop;
                    end if;
                    if q_m(8) = '0' then
                        cnt <= cnt + to_signed(n1_q_m - n1_n0, 5);
                    else
                        cnt <= cnt - to_signed(n1_q_m - n1_n0, 5);
                    end if;
                else
                    if (cnt > 0 and n1_q_m > n1_n0) or
                       (cnt < 0 and n1_q_m < n1_n0) then
                        tmds(9) <= '1';
                        tmds(8) <= q_m(8);
                        for i in 0 to 7 loop
                            tmds(i) <= not q_m(i);
                        end loop;
                        if q_m(8) = '1' then
                            cnt <= cnt + to_signed(n1_q_m - n1_n0, 5);
                        else
                            cnt <= cnt - to_signed(n1_q_m - n1_n0, 5);
                        end if;
                    else
                        tmds(9) <= '0';
                        tmds(8) <= q_m(8);
                        for i in 0 to 7 loop
                            tmds(i) <= q_m(i);
                        end loop;
                        if q_m(8) = '0' then
                            cnt <= cnt + to_signed(n1_q_m - n1_n0, 5);
                        else
                            cnt <= cnt - to_signed(n1_q_m - n1_n0, 5);
                        end if;
                    end if;
                end if;
            else
                -- Fase di controllo: trasmette solo hsync/vsync
                case (hsync & vsync) is
                    when "00" => tmds <= "1101010100";
                    when "01" => tmds <= "0010101011";
                    when "10" => tmds <= "0101010100";
                    when "11" => tmds <= "1010101011";
                    when others => tmds <= "1101010100";
                end case;
            end if;
        end if;
    end process;
end architecture;
