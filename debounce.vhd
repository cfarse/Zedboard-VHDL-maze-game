library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--============================================================================
-- Debounce
-- Filtra i rimbalzi dei pulsanti tramite:
--   1) doppio flip-flop per sincronizzazione/metastabilità
--   2) contatore di stabilità (richiede COUNTER_SIZE+1 cicli stabili)
--
-- Con COUNTER_SIZE = 19 e clk = 100 MHz (ZedBoard):
--   tempo di debounce = 2^20 / 100e6 ≈ 10.49 ms
--
-- Uscite:
--   btn_out     : livello debounced (stabile)
--   btn_pressed : impulso di 1 ciclo su fronte di salita (premuto)
--   btn_released: impulso di 1 ciclo su fronte di discesa (rilasciato)
--============================================================================
entity Debounce is
    generic(
        COUNTER_SIZE : integer := 19   -- 2^20 cicli @ 100 MHz ≈ 10.49 ms
    );
    port(
        clk          : in  std_logic;   -- 100 MHz ZedBoard
        rst          : in  std_logic;   -- reset sincrono attivo alto
        btn_in       : in  std_logic;   -- input grezzo dal pulsante
        btn_out      : out std_logic;   -- livello debounced
        btn_pressed  : out std_logic;   -- impulso su pressione (1 ciclo)
        btn_released : out std_logic    -- impulso su rilascio (1 ciclo)
    );
end entity Debounce;

architecture Behavioral of Debounce is

    -- Sincronizzatore a 2 flip-flop
    signal sync_ff      : std_logic_vector(1 downto 0) := (others => '0');

    -- Contatore di stabilità
    signal counter      : unsigned(COUNTER_SIZE downto 0) := (others => '0');

    -- Stato interno debounced (prima di generare gli edge)
    signal btn_stable   : std_logic := '0';
    signal btn_stable_d : std_logic := '0';

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sync_ff      <= (others => '0');
                counter      <= (others => '0');
                btn_stable   <= '0';
                btn_stable_d <= '0';
                btn_out      <= '0';
                btn_pressed  <= '0';
                btn_released <= '0';
            else
                -- 1) Sincronizzazione input (anti-metastabilità)
                sync_ff(0) <= btn_in;
                sync_ff(1) <= sync_ff(0);

                -- 2) Contatore di stabilità
                if sync_ff(1) /= btn_stable then
                    -- Input diverso dallo stato stabile: riparti da zero
                    counter <= (others => '0');
                elsif counter(COUNTER_SIZE) = '0' then
                    -- Input uguale allo stato stabile: incrementa
                    counter <= counter + 1;
                end if;

                -- 3) Aggiorna lo stato stabile quando il tempo è scaduto
                if counter(COUNTER_SIZE) = '1' then
                    btn_stable <= sync_ff(1);
                end if;

                -- 4) Ritardo dello stato stabile per generare gli edge
                btn_stable_d <= btn_stable;

                -- 5) Uscite
                btn_out      <= btn_stable;
                btn_pressed  <= btn_stable and not btn_stable_d;  -- fronte di salita
                btn_released <= (not btn_stable) and btn_stable_d; -- fronte di discesa
            end if;
        end if;
    end process;

end architecture Behavioral;
