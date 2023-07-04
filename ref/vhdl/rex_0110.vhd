-- *********************************************************************
-- File:			REX Project
-- Date:			April 24, 2011
-- Version:		REX
--					revision 0110
-- Designer:	Stephen Adolph 
-- *********************************************************************

-- based on V5 0101 firmware

-- notes for setting the fitter parameters
-- unused input pin termination = pullup
-- input pin termination = pullup
-- power up defaults must be '1' for flip flops

-- bug fix relating to reset
-- simpified ALE internal flip flops, eliminated cs_OPT flip flop
-- eliminated REX2 from support in this stream.  REX2 must be supported from a specific
-- REX2 build.

------------------------------------------------------------------------
-- define a positive edge triggered clock register
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity regis is
port( 	rst, clk, clk_en, clr, default 	: in std_logic;
		input						: in std_logic;
		output						: out std_logic
	);
end regis;

architecture regis_rtl of regis is
begin
process(rst, clk, clk_en, clr, default, input)
	begin
		if (rst='1') then
			output <= default;
		elsif (clr='1') then
			output <= default;
		elsif  (clk_en = '1') then
   			if (clk'event and clk='1') then
			  	output <= input;
		  	end if;
		end if;
	end process;
end regis_rtl;

------------------------------------------------------------------------
-- define a positive edge triggered clock register vector
------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity regis_vector is
port( 	rst, clk, clk_en, clr, default 	: in std_logic;
		input					: in std_logic_vector;
		output					: out std_logic_vector
	);
end regis_vector;

architecture regis_rtl_vector of regis_vector is
begin
	reg_gen: for ix in input'RANGE generate
	begin
		process(rst, clk, clk_en, clr, default, input)
		begin
			if (rst='1') then
				output(ix) <= default;
			elsif (clr='1') then
				output(ix) <= default;
			elsif  (clk_en = '1') then
				if (clk'event and clk='1') then
					output(ix) <= input(ix);
				end if;
			end if;
		end process;
	end generate reg_gen;
end regis_rtl_vector;




------------------------------------------------------------------------
-- define a Rex
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
entity rexbrd is
   Port (	
   		-- M100 Interface signals
		ad													: inout std_logic_vector(7 downto 0);	
		rd, ale, cs_OPT								: in std_logic;

--		reset												: in std_logic;
-- not used in this design

		-- reset active low, and is driven to the flash chip
		-- rst active high
		
		-- 	tp1 is cs_main1, TP2 is csmain2
		cs_MAIN1											: in std_logic;
		cs_MAIN2A										: in std_logic;


	    	
		--  Memory interface signals	
		au												: out std_logic_vector(19 downto 15);
		al												: out std_logic_vector(7 downto 0);
		we, ce, oe									: out std_logic;					
		ryby											: in std_logic



		);
end rexbrd;

architecture rex_rtl of rexbrd is

------------------------------------------------------------------------
-- instatiate the positive edge triggered register
------------------------------------------------------------------------
component regis is
port	( 	rst, clk, clk_en, clr, default, input	: in std_logic;
		output							: out std_logic
	);
end component;


-----------------------------------------------------------------------
-- instatiate the positive edge triggered register vector
------------------------------------------------------------------------
component regis_vector is
port( 	rst, clk, clk_en, clr, default 	: in std_logic;
		input					: in std_logic_vector;
		output					: out std_logic_vector
	);
end component;




-- SIGNAL definitions ------------------------------------------------------------------------------------------

signal al_lo, al_reg_in, gp_reg_in, gp_data					: std_logic_vector(7 downto 0);
signal nState, state						: std_logic_vector(2 downto 0);
signal ad_in								: std_logic_vector(7 downto 0);
signal ad_dir, al_en						: std_logic;
signal sector								: std_logic_vector(4 downto 0);
signal sector_en							: std_logic;
signal gp_en, counter_on								: std_logic;
signal ad_data, ad_reg_in				: std_logic_vector(7 downto 0);
signal ad_out_en  						: std_logic;

signal rex_active, romsel, cs_MAIN2				: std_logic;
signal cs_MAIN_v							: std_logic_vector(1 downto 0);

signal rst					: std_logic;

signal s_en, a1_en, ad_en				: std_logic;
signal ce_rex, we_rex, oe_rex				: std_logic;

signal count, nCount									:std_logic_vector(2 downto 0);
signal count_clr									:std_logic;
signal key_vector														:std_logic_vector(10 downto 0);

signal control, nControl		: std_logic;

signal ale_int, ale_high_pulse, ale_clr, ale_count		: std_logic;

signal default_vector					: std_logic_vector(25 downto 0);


--------------------------------------------------------------------------------------------------------

constant HW_version : std_logic_vector(7 downto 6) :="00"; 
-- HW 00 = REX
-- HW 01 = REX2
-- HW 10 = unassigned
-- HW 11 = unassigned

constant model : std_logic_vector(1 downto 0) := '0' & '1';  -- no ram suport, rom supported

-- model 00 = base model + no extra features 							(valid with HW 00, 01)
-- model 01 = base model + main rom replacement  						(valid with HW 00, 01)
-- model 10 = base model + RAM support  									(valid with HW 01)
-- model 11 = base model + main rom replacement + RAM support  	(valid with HW 01)

constant FW_version : std_logic_vector(5 downto 0) :="0110" & model;

begin

------------------------------------------------------------------------
-- create a delayed internal ALE 
-- first one toggles down on ale falling edge
-- reset by ale_clr
-- FF power up default is '1', and default on clear/reset is '1'
------------------------------------------------------------------------
ale_clr_flop:		regis port map ('0',      ale, '1', ale_clr, '1', '0', ale_high_pulse);
ale_int_flop:		regis port map ('0', not(ale), '1', ale_clr, '1', '0', ale_int);

ale_clr <= '1' when ale='1' and (ale_int='0' or ale_high_pulse='0') else '0';



------------------------------------------------------------------------
-- reset circuit
-- detect first rising edge of ALE, and
-- enable the ale_clr singal as a reset pulse.
-- reset should be complete before falling edge of ALE.
-- FF power up default is '1', and default on clear/reset is '1'
------------------------------------------------------------------------

ale_counter:		regis port map ('0', not(ale), ale_count, '0', '1', not(ale_count), ale_count);

default_vector <= state & control & sector & romsel & gp_data & al_lo;

process (ale, ale_count, default_vector)
begin
	case ale_count is
	when '1' =>
	
		case ale is
		when '1'=>
		
			case default_vector is
			when "11110000000000000000000000" =>
			rst <= '0'; 
			when others =>
			rst <= '1';
			end case;
			
		when others =>
		rst <= '0';
		end case;
		
	when others =>	
		rst <= '0';
	end case;	

end process;



cs_MAIN2 <= '0' when (cs_MAIN1 = '1' and cs_MAIN2a = '0') else '1';
-- this is needed because of extra chip select of A15 on 8k ROM

rex_active <= (cs_OPT and cs_MAIN1 and cs_MAIN2) when state = "111" else cs_OPT;	-- if either is 0 then result 0

ce <= ce_rex or rex_active;
oe <= oe_rex or rex_active or rd;
we <= we_rex or rex_active or rd;

------------------------------------------------------------------------
-- define the state machine that controls the flash
------------------------------------------------------------------------
key_vector <= ad_in & count;

process (	state, ad_in, ale, rd, ryby, sector, romsel, ad_data, key_vector, control)
begin

case state is
								-- normal flash reads occuring
when "111" =>				-- start searching for keys

	case key_vector is 
	when "10111000000" =>		-- key #1 184
		nState <= "111"; 
		count_clr <= '0';
		counter_on <= '1';
	when "11110010001" =>		-- key #2 242	
		nState <= "111"; 
		count_clr <= '0';
		counter_on <= '1';
	when "00110100010" =>		-- key #3 52
		nState <= "111"; 
		count_clr <= '0';
		counter_on <= '1';
	when "10110000011" =>		-- key #4 176	
		nState <= "111"; 
		count_clr <= '0';		
		counter_on <= '1';
	when "00110001100" =>		-- key #5 49
		nState <= "111"; 
		count_clr <= '0';	
		counter_on <= '1';
	when "10111111101" =>		-- key #6 191 	
		nState <= "000"; 
		count_clr <= '0';		
		counter_on <= '0';
	when others =>
		nState <= "111";
		count_clr <= '1';	
		counter_on <= '1';
	end case;

	ad_reg_in <= ad_in;
	ad_en <= '1';
	al_reg_in <= ad_in;
	al_en <= '1';
	nControl <= '0';
	
	ad_dir <= '1';
	we_rex <= '1';
	ce_rex <= '0';
	oe_rex <= '0';	

------------------------------------------------------------------------
-- read command 000
------------------------------------------------------------------------
when "000" =>						-- read in command

	case ad_in(2 downto 0) is
	when "001" => 					-- set sector CMD1
		nState <= "001";			-- go to set sector state
		ad_reg_in <= ad_in;		-- data don't care, address - don't care
	when "011" => 					-- read status CMD3
		nState <= "011";			-- output from REX to CPU
		ad_reg_in <= ryby & romsel & '0' & sector; 		-- latch data - needed!, address - don't care
	when "100" =>					-- normal memory read CMD4
		nState <= "100";			-- go to latch address state
		ad_reg_in <= ad_in;		-- data don't care, address don't care
	when "010" =>					-- send AAA (A0 80 AA) CMD AA/2
		nState <= "010";			-- go to load data state
		ad_reg_in <= ad_in;		-- data don't care, latch address - AA
	when "101" =>					-- send 555 55 CMD 55/5
		nState <= "010";			-- go to load data state
		ad_reg_in <= ad_in;		-- data don't care, latch address - AA
	when "110" => 					-- send (PA PD)(SA 30) CMD 06
		nState <= "110";			-- go to get address state
		ad_reg_in <= ad_in;		-- data don't care, address don't care	
	when "111" => 					-- read hw/fw ID CMD7
		nState <= "011";			-- output from REX to CPU
		ad_reg_in <= HW_version & FW_version;	-- latch data - needed!, address - don't care
	when others => 		
		nState <= "111";			-- if command 00, return to start of key search
		ad_reg_in <= ad_in;
	end case;
	ad_en <= '1';
	al_reg_in <= ad_in;
	al_en <= '1';		-- latch it
	count_clr <= '1';			
	counter_on <= '0';	
	nControl <= '0';

	ad_dir <= not(control);			-- write to flash from REX in state 000
	we_rex <= not(control);	
	ce_rex <= not(control);
	oe_rex <= '1';
	
------------------------------------------------------------------------
-- set sector command, 001
------------------------------------------------------------------------
	
when "001" =>	 							-- set sector
	nState <= "000";						-- latch sector data into sector register
	ad_reg_in <= ad_in;			-- don't care
	ad_en <= '1';
	al_reg_in <= ad_in;			-- don't care
	al_en <= '1';			
	count_clr <= '1';
	counter_on <= '0';	
	nControl <= '0';
	
	ad_dir <= '1';			
	we_rex <= '1';				
	ce_rex <= '1';		
	oe_rex <= '1';
	
------------------------------------------------------------------------
-- load address latch, 110
------------------------------------------------------------------------

when "110" =>			-- latch in the lower address byte

	nState <= "010";	-- load ad register next
	ad_reg_in <= ad_in;		-- don't care
	ad_en <= '1';
	al_reg_in <= ad_in;
	al_en <= '1';			-- latch address byte
	count_clr <= '1';
	counter_on <= '0';	
	nControl <= '0';
	
	ad_dir <= '1';			-- all other states
	we_rex <= '1';				
	ce_rex <= '1';		
	oe_rex <= '1';

------------------------------------------------------------------------
-- load D into AD  010
------------------------------------------------------------------------

when "010" =>				-- load D from AD_in
	nState <= "000";		-- do the write
	ad_reg_in <= ad_in;		-- latch in data here		
	ad_en <= '1';
	al_reg_in <= ad_in;
	al_en <= '0';			-- don't latch!
	count_clr <= '1';	
	counter_on <= '0';	
	nControl <= '1';		-- make state 000 an output to flash state next
	
	ad_dir <= '1';			
	we_rex <= '1';				
	ce_rex <= '1';		
	oe_rex <= '1';
	
------------------------------------------------------------------------
-- read from REX to CPU 011
------------------------------------------------------------------------

when "011" => 				
	nState <= "000";
	ad_reg_in <= ad_in;		-- don't care
	ad_en <= '1';
	al_reg_in <= ad_in;		-- don't care
	al_en <= '1';
	count_clr <= '1';
	counter_on <= '0';	
	nControl <= '0';

	ad_dir <= '0';			-- write to CPU from REX
	we_rex <= '1';	
	ce_rex <= '1';
	oe_rex <= '1';	

------------------------------------------------------------------------
-- load address latch, 100
------------------------------------------------------------------------

when "100" =>			-- latch in the lower address byte
	nState <= "101";	-- read from flash state
	ad_reg_in <= ad_in;		-- don't care
	ad_en <= '1';
	al_reg_in <= ad_in;
	al_en <= '1';			-- latch address byte
	count_clr <= '1';
	counter_on <= '0';	
	nControl <= '0';
	
	ad_dir <= '1';			-- all other states
	we_rex <= '1';				
	ce_rex <= '1';		
	oe_rex <= '1';

------------------------------------------------------------------------
-- normal memory read, 101
------------------------------------------------------------------------

when others => 			--101					
	nState <= "000";
	ad_reg_in <= ad_in;		-- don't care
	ad_en <= '1';
	al_reg_in <= ad_in;		-- don't latch!
	al_en <= '0';
	count_clr <= '1';
	counter_on <= '0';
	nControl <= '0';
	
	ad_dir <= '1';			-- do a normal memory read
	we_rex <= '1';
	ce_rex <= '0';
	oe_rex <= '0';	

end case;
end process;

------------------------------------------------------------------------
-- create a register to control outputs in state 000
------------------------------------------------------------------------
control_1: 	regis 	port map (rst, not(ale_int), not(cs_OPT), '0', '1', nControl, control);

------------------------------------------------------------------------
-- create the state register
------------------------------------------------------------------------
state_reg: 	regis_vector 	port map (rst, not(ale_int), not(cs_OPT), '0', '1', nState, state);

------------------------------------------------------------------------
-- create the sector register, default sector is 00000
------------------------------------------------------------------------

sector_0: 	regis_vector 	port map (rst, not(ale_int), s_en, '0', '0', ad_in(4 downto 0), sector);


s_en <= sector_en and not(cs_OPT);
sector_en <= '1' when state = "001" else '0';

------------------------------------------------------------------------
-- select the output of lvau to be sector when optrom selected, or 
-- a specific bank when main rom selected.
-- create the rom selector, default sector is 0
------------------------------------------------------------------------

cs_MAIN_v <= cs_MAIN1 & cs_MAIN2;

process (cs_MAIN_v, romsel, sector)
begin
	case cs_MAIN_v is
	when "01" =>		--  romsel =0, 2 and 3 are grouped, romsel = 1, 4 and 5 are grouped
		au(19 downto 15) <= '0' & '0' & romsel & not(romsel) & '0';
	when "10" =>
		au(19 downto 15) <= '0' & '0' & romsel & not(romsel) & '1';	
	when others =>	
		au(19 downto 15) <= sector;	
	end case;	

end process;

rom_selector: 	regis 	port map (rst, not(ale_int), s_en, '0', '0', ad_in(6), romsel);	


------------------------------------------------------------------------
-- create the al register
-- active whenever REX is active
------------------------------------------------------------------------
al_reg: 		regis_vector 	port map (rst, not(ale_int), a1_en, '0', '0', al_reg_in, al_lo);
al <= al_lo;
a1_en <= al_en and not(rex_active);


------------------------------------------------------------------------
-- control the behaviour of the AD port on Rex
-- output only when the option rom is selected
-- output ad_dir=0, input ad_dir=1
------------------------------------------------------------------------
ad_in <= "00000000" when ad_out_en = '0' else ad;
ad <= ad_data when ad_out_en='0' else "ZZZZZZZZ";
ad_out_en <=  ad_dir or rd or cs_OPT;


------------------------------------------------------------------------
-- create the general purpose register, used for ad and for counter
------------------------------------------------------------------------

gp_0: 		regis_vector 	port map (rst, not(ale_int), gp_en, '0', '0', gp_reg_in, gp_data);
gp_en <= ad_en and not(cs_OPT);

gp_reg_in(7 downto 5) <= nCount when counter_on = '1' else ad_reg_in(7 downto 5);
gp_reg_in(4 downto 0) <= ad_reg_in(4 downto 0);

ad_data <= gp_data;
count <= gp_data(7 downto 5);


------------------------------------------------------------------------
-- define the counter
------------------------------------------------------------------------

nCount(0) <= not(count(0)) and not(count_clr);		-- counts when count_clr = 0, cleared when count_clr = '1'
nCount(1) <= (count(1) xor count(0)) and not(count_clr);
nCount(2) <= (count(2) xor (count(1) and count(0))) and not(count_clr);


end rex_rtl;

