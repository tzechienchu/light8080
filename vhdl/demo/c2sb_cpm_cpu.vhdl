--#############################################################################
-- CP/M on SD card for fpga-8080 core
--#############################################################################
-- 
--#############################################################################
-- PORT ADDRESSES:
-- 20h : in         status serial port
-- 21h : in/out     data serial port
-- 22h : out        general control port
-- 40h : in         switches
-- 40h : out        green leds
-- 50h : out        single-step trace control port

--#############################################################################
-- CONTROL PORT
-- (0) block paged at 0000h-07ffh: '0'=ROM, '1'=RAM
--#############################################################################
-- SERIAL PORT
-- TODO doc this!
--#############################################################################
-- SD card interface
-- TODO doc this!
--#############################################################################
-- SINGLE-STEP TRACE CONTROL PORT
-- (0) enable single step interrupt:  '0'=disable, '1'=enable
-- The interrupt request line intr is directly connected to this bit.
--#############################################################################

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;


-- NOTE: all that's necessary for the demo is the SRAM and the SD interface.
entity c2sb_cpm_cpu is
    port ( 
        -- ***** Clocks
        clk_50MHz     : in std_logic;

        -- ***** Flash 4MB
        flash_addr    : out std_logic_vector(21 downto 0);
        flash_data    : in std_logic_vector(7 downto 0);
        flash_oe_n    : out std_logic;
        flash_we_n    : out std_logic;
        flash_reset_n : out std_logic;

        -- ***** SRAM 256K x 16
        sram_addr     : out std_logic_vector(17 downto 0);
        sram_data     : inout std_logic_vector(15 downto 0);
        sram_oe_n     : out std_logic;
        sram_ub_n     : out std_logic;
        sram_lb_n     : out std_logic;        
        sram_ce_n     : out std_logic;
        sram_we_n     : out std_logic;        

        -- ***** RS-232
        rxd           : in std_logic;
        txd           : out std_logic;

        -- ***** Switches and buttons
        switches      : in std_logic_vector(9 downto 0);
        buttons       : in std_logic_vector(3 downto 0);

        -- ***** Quad 7-seg displays
        hex0          : out std_logic_vector(0 to 6);
        hex1          : out std_logic_vector(0 to 6);
        hex2          : out std_logic_vector(0 to 6);
        hex3          : out std_logic_vector(0 to 6);

        -- ***** Leds
        red_leds      : out std_logic_vector(9 downto 0);
        green_leds    : out std_logic_vector(7 downto 0);

        -- ***** SD Card
        sd_data       : in  std_logic;
        sd_cs         : out std_logic;
        sd_cmd        : out std_logic;
        sd_clk        : out std_logic           
    );
end c2sb_cpm_cpu;

architecture sd_card of c2sb_cpm_cpu is

component light8080
port (  
  addr_out :  out std_logic_vector(15 downto 0);

  inta :      out std_logic;
  inte :      out std_logic;
  halt :      out std_logic;                
  intr :      in std_logic;
              
  vma :       out std_logic;
  io :        out std_logic;
  rd :        out std_logic;
  wr :        out std_logic;
  data_in :   in std_logic_vector(7 downto 0);  
  data_out :  out std_logic_vector(7 downto 0);

  clk :       in std_logic;
  reset :     in std_logic );
end component;

-- Serial port, RX 
component rs232_rx
port(
    rxd       : IN std_logic;
    read_rx   : IN std_logic;
    clk       : IN std_logic;
    reset     : IN std_logic;          
    data_rx   : OUT std_logic_vector(7 downto 0);
    rx_rdy    : OUT std_logic
    );
end component;

-- Serial port, TX
component rs232_tx
port(
    clk       : IN std_logic;
    reset     : IN std_logic;
    load      : IN std_logic;
    data_i    : IN std_logic_vector(7 downto 0);          
    rdy       : OUT std_logic;
    txd       : OUT std_logic
    );
end component;

-- Program ROM
component c2sb_cpm_rom
    port ( 
        clk           : in std_logic;
        addr          : in std_logic_vector(15 downto 0);
        data_out      : out std_logic_vector(7 downto 0)
    );
end component;



--##############################################################################
-- light8080 CPU system signals

signal data_in :          std_logic_vector(7 downto 0);
signal vma :              std_logic;
signal rd :               std_logic;
signal wr  :              std_logic;
signal io  :              std_logic;
signal data_out :         std_logic_vector(7 downto 0);
signal addr :             std_logic_vector(15 downto 0);
signal inta :             std_logic;
signal inte :             std_logic;
signal intr :             std_logic;
signal halt :             std_logic;

-- signals for sram 'synchronization' 
signal sram_data_out :    std_logic_vector(7 downto 0); -- sram output reg
signal sram_write :       std_logic; -- sram we register

-- signals for debug
signal address_reg :      std_logic_vector(15 downto 0); -- registered addr bus


--##############################################################################
-- General I/O control signals

signal io_q :             std_logic;
signal rd_q :             std_logic;
signal io_read :          std_logic;
signal io_write :         std_logic;

--##############################################################################
-- RS232 signals

signal rx_rdy :           std_logic;
signal tx_rdy :           std_logic;
signal rs232_data_rx :    std_logic_vector(7 downto 0);
signal rs232_status :     std_logic_vector(7 downto 0);
signal data_io_out :      std_logic_vector(7 downto 0);
signal io_port :          std_logic_vector(7 downto 0);
signal read_rx :          std_logic;
signal write_tx :         std_logic;


--##############################################################################
-- Application signals

-- general control port (rom paging)
signal reg_control :      std_logic_vector(7 downto 0);

signal reg_display_h :    std_logic_vector(7 downto 0);
signal reg_display_l :    std_logic_vector(7 downto 0);


--##############################################################################
-- Quad 7-segment display (non multiplexed) & LEDS

signal display_data :     std_logic_vector(15 downto 0);
signal reg_gleds :        std_logic_vector(7 downto 0);  

-- i/o signals
signal data_io_in :       std_logic_vector(7 downto 0);
signal data_mem_in :      std_logic_vector(7 downto 0);
signal data_rom_in :      std_logic_vector(7 downto 0);
signal rom_access :       std_logic;
signal rom_space :        std_logic;
signal breakpoint :       std_logic;


-- Clock & reset signals
signal clk_25MHz :        std_logic;
signal clk_div :          std_logic_vector(1 downto 0);
signal reset :            std_logic;
signal clk :              std_logic;

-- SD control signals
signal sd_in :            std_logic;
signal reg_sd_dout :      std_logic;
signal reg_sd_clk :       std_logic;
signal reg_sd_cs :        std_logic;

-- Single step interrupt register
signal reg_trace :        std_logic_vector(7 downto 0);

begin

-- program ROM
program_rom : c2sb_cpm_rom port map(
    clk => clk,
    addr => addr,
    data_out => data_rom_in
  );

-- rom CS decoder
rom_space <= '1' when (reg_control(0)='0' and addr(15 downto 11) = "00000")
             else  '0';

-- registered rom CS 
process(clk)
begin
  if (clk'event and clk='1') then
    if reset='1' then
      rom_access <= '1';
      breakpoint <= '0';
    else
      if rd='1' and rom_space='1' then
        rom_access <= '1';
      else
        rom_access <= '0';
      end if;
      
      if rd='1' and io='0' and addr = X"dc00" and switches(9)='1' then
        breakpoint <= '1';
      else
        breakpoint <= '0';
      end if;
      
    end if;
  end if;
end process;

-- rom vs. ram mux
data_mem_in <=  data_rom_in when rom_access='1' and breakpoint='0' else 
                X"FF" when breakpoint='1' else
                sram_data(7 downto 0);


-- output port registers
process(clk)
begin
  if (clk'event and clk='1') then
    if reset='1' then
      reg_gleds   <= X"00";
      reg_control <= X"00";
      reg_display_h <= X"00";
      reg_display_l <= X"00";
      reg_trace <= X"00";
      reg_sd_dout <= '0';
      reg_sd_clk <= '0';
      reg_sd_cs <= '0';
    else
      if io_write='1' then
        if addr(7 downto 0)=X"40" then
          reg_gleds <= data_out;
        end if;
        if addr(7 downto 0)=X"22" then
          reg_control <= data_out;
        end if;
        if addr(7 downto 0)=X"23" then
          reg_display_l <= data_out;
        end if;
        if addr(7 downto 0)=X"24" then
          reg_display_h <= data_out;
        end if;
        if addr(7 downto 0)=X"50" then
          reg_trace <= data_out;
        end if;
        if addr(7 downto 1)="1001000" then -- 80h,81h
          reg_sd_dout <= addr(0);
        end if;
        if addr(7 downto 1)="1001001" then -- 82h,83h
          reg_sd_clk <=addr(0);
        end if;
        if addr(7 downto 1)="1001010" then -- 84h,85h
          reg_sd_cs <= addr(0);
        end if;
      end if;
    end if;
  end if;
end process;


-- CPU control signals
intr <= reg_trace(0); -- the only intr source is the trace function

-- CPU instance
cpu: light8080 port map(
    clk => clk,
    reset => reset,
    vma => vma,
    rd => rd,
    wr => wr,
    io => io,
    addr_out => addr, 
    data_in => data_in,
    data_out => data_out,
    intr => intr,
    inte => inte,
    inta => inta,
    halt => halt
);


process(clk)
begin
  if clk'event and clk = '1' then
    if reset = '1' then
      io_q <= '0';  
      rd_q <= '0';        
      io_port <= X"00"; 
      data_io_out <= X"00";
    else
      io_q <= io;   
      rd_q <= rd;       
      io_port <= addr(7 downto 0);      
      data_io_out <= data_out;
    end if;
  end if;
end process;

-- red leds (light with '1') -- some CPU control signals 
red_leds(0) <= halt;
red_leds(1) <= inte;
red_leds(2) <= vma;
red_leds(3) <= rd;
red_leds(4) <= wr;

red_leds(9) <= tx_rdy;
red_leds(8) <= rx_rdy;
red_leds(7) <= rom_space;
red_leds(6) <= intr;
red_leds(5) <= inta;

--##### Input ports ###########################################################

-- mem vs. io input mux
data_in <=  data_io_in    when io_q='1' and inta='0' else -- I/O port data 
            data_mem_in   when io_q='0' and inta='0' else -- MEM data
            X"ff";                                        -- IRQ vector (RST 7)

-- io read enable (for async io ports; data read in cycle following io='1')
io_read <= '1' when io_q='1' and rd_q='1' else '0';

-- io write enable (for sync io ports; data written in cycle following io='1') 
io_write <= '1' when io='1' and wr='1' else '0';

-- read/write signals for rs232 modules
read_rx <=  '1' when io_read='1' and addr(7 downto 0)=X"21" else '0';
write_tx <= '1' when io_write='1' and addr(7 downto 0)=X"21" else '0';

-- synchronized input port mux (using registered port address)
with io_port(7 downto 0) select
  data_io_in <= rs232_status          when X"20",
                rs232_data_rx         when X"21",
                sd_in & "0000000"     when X"88",
                switches(7 downto 0)  when others; -- 40h
                

--##############################################################################
-- terasIC Cyclone II STARTER KIT BOARD
--##############################################################################

--##############################################################################
-- FLASH (flash is unused in this demo)
--##############################################################################

flash_addr <= (others => '0');

flash_we_n <= '1'; -- all enable signals inactive
flash_oe_n <= '1';
flash_reset_n <= '1';


--##############################################################################
-- SRAM (used as 64K x 8)
--
-- NOTE: All writes go to SRAM independent of rom paging status
--##############################################################################

process(clk)
begin
  if clk'event and clk='1' then
    if reset='1' then
      sram_addr <= "000000000000000000";
      address_reg <= "0000000000000000";
      sram_data_out <= X"00";
      sram_write <= '0';
    else
      -- load address register
      if vma='1' and io='0' then 
        sram_addr <= "00" & addr;
        address_reg <= addr;
      end if;
      -- load data and write enable registers 
      if vma='1' and wr='1' and io='0' then
        sram_data_out <= data_out;
        sram_write <= '1';
      else
        sram_write <= '0';
      end if;
    end if;
  end if;
end process;

sram_data(15 downto 8) <= "ZZZZZZZZ"; -- high byte unused
sram_data(7 downto 0)  <= "ZZZZZZZZ" when sram_write='0' else sram_data_out;  
-- (the X"ZZ" will physically be the read input data)

-- sram access controlled by WE_N
sram_oe_n <= '0'; 
sram_ce_n <= '0'; 
sram_we_n <= not sram_write;
sram_ub_n <= '1'; -- always disable
sram_lb_n <= '0';

--##############################################################################
-- RESET, CLOCK
--##############################################################################

-- Use button 3 as reset
reset <= not buttons(3);

-- Generate a 1-Hz clock for visual reference 
process(clk_50MHz)
begin
  if clk_50MHz'event and clk_50MHz='1' then
        if clk_div(0) = '1' then
          clk_div <= (others => '0');
          clk_25MHz <= not clk_25MHz;
        else
          clk_div <= clk_div + 1;
        end if;
  end if;
end process;

-- Master clock is 25MHz
clk <= clk_25MHz;

--##############################################################################
-- LEDS, SWITCHES
--##############################################################################

green_leds <= sd_in & reg_sd_dout & "000" & reg_sd_cs & reg_sd_clk & clk;
--reg_gleds; 


--##############################################################################
-- QUAD 7-SEGMENT DISPLAYS
--##############################################################################

-- we'll be displaying valid memory addresses in the hex display
process(clk)
begin
  if clk'event and clk='1' then
    if vma = '1' then
      display_data <= addr(15 downto 0);
    end if;
  end if;
end process;

--display_data <= addr(15 downto 0) when switches(9)='1' else
--                reg_display_h & reg_display_l;

-- 7-segment encoders; the dev board displays are not multiplexed or encoded

with display_data(15 downto 12) select hex3 <=  
"0000001" when X"0","1001111" when X"1","0010010" when X"2","0000110" when X"3",
"1001100" when X"4","0100100" when X"5","0100000" when X"6","0001111" when X"7",
"0000000" when X"8","0000100" when X"9","0001000" when X"a","1100000" when X"b",
"0110001" when X"c","1000010" when X"d","0110000" when X"e","0111000" when others;          
          
with display_data(11 downto 8) select hex2 <= 
"0000001" when X"0","1001111" when X"1","0010010" when X"2","0000110" when X"3",
"1001100" when X"4","0100100" when X"5","0100000" when X"6","0001111" when X"7",
"0000000" when X"8","0000100" when X"9","0001000" when X"a","1100000" when X"b",
"0110001" when X"c","1000010" when X"d","0110000" when X"e","0111000" when others;          
          
with display_data(7 downto 4) select hex1 <=  
"0000001" when X"0","1001111" when X"1","0010010" when X"2","0000110" when X"3",
"1001100" when X"4","0100100" when X"5","0100000" when X"6","0001111" when X"7",
"0000000" when X"8","0000100" when X"9","0001000" when X"a","1100000" when X"b",
"0110001" when X"c","1000010" when X"d","0110000" when X"e","0111000" when others;

with display_data(3 downto 0) select hex0 <=  
"0000001" when X"0","1001111" when X"1","0010010" when X"2","0000110" when X"3",
"1001100" when X"4","0100100" when X"5","0100000" when X"6","0001111" when X"7",
"0000000" when X"8","0000100" when X"9","0001000" when X"a","1100000" when X"b",
"0110001" when X"c","1000010" when X"d","0110000" when X"e","0111000" when others;

--##############################################################################
-- SD
--##############################################################################

sd_cs     <= reg_sd_cs;
sd_cmd    <= reg_sd_dout;
sd_clk    <= reg_sd_clk;
sd_in     <= sd_data;


--##############################################################################
-- SERIAL
--##############################################################################

--txd <= rxd; -- loopback rs-232

serial_rx : rs232_rx port map(
    rxd => rxd,
    data_rx => rs232_data_rx,
    rx_rdy => rx_rdy,
    read_rx => read_rx,
    clk => clk_50MHz,
    reset => reset 
  );

serial_tx : rs232_tx port map(
    clk => clk_50MHz,
    reset => reset,
    rdy => tx_rdy,
    load => write_tx,
    data_i => data_out,
    txd => txd
  );

rs232_status <= (not tx_rdy) & "000000" & (not rx_rdy);


end sd_card;
