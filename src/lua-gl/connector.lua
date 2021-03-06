-- Module to handle connectors for lua-gl

local table = table
local type = type
local floor = math.floor
local min = math.min
local abs = math.abs
local tonumber = tonumber
local error = error
local pairs = pairs
local tostring = tostring
local iup = iup

local utility = require("lua-gl.utility")
local tu = require("tableUtils")
local coorc = require("lua-gl.CoordinateCalc")
local router = require("lua-gl.router")
local GUIFW = require("lua-gl.guifw")
local PORTS = require("lua-gl.ports")

-- Only for debug
local print = print

local M = {}
package.loaded[...] = M
if setfenv and type(setfenv) == "function" then
	setfenv(1,M)	-- Lua 5.1
else
	_ENV = M		-- Lua 5.2+
end

-- The connector structure looks like this:
--[[
{
	id = <string>,		-- unique ID for the connector. Format is C<num> i.e. C followed by a unique number
	order = <integer>,	-- Index in the order array
	segments = {	-- Array of segment structures
	-- Number of segments can be zero on a connector only if it is connecting 2 overlapping ports
		[i] = {
			start_x = <integer>,		-- starting coordinate x of the segment
			start_y = <integer>,		-- starting coordinate y of the segment
			end_x = <integer>,			-- ending coordinate x of the segment
			end_y = <integer>			-- ending coordinate y of the segment
			vattr = <table>				-- (OPTIONAL) table containing the object visual attributes. If not present object drawn with default drawing settings
		}
	},
	port = {		-- Array of port structures to which this connector is connected to. Needed back info to merge or delete connectors
		[i] = <port structure>,
	},
	junction = {	-- Array of junction structures
		[i] = {
			x = <integer>,		-- X coordinate of the junction
			y = <integer>		-- Y coordinate of the junction
		},
	},
	vattr = <table>				-- (OPTIONAL) table containing the object visual attributes. If not present object drawn with default drawing settings
}
]]
-- The connector structure is located in the array cnvobj.drawn.conn
-- Note a connector never crosses a port. If a port is placed on a connector the connector is split into 2 connectors, one on each side of the port.

-- Returns the connector structure given the connector ID
getConnFromID = function(cnvobj,connID)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	if not connID or not connID:match("C%d%d*") then
		return nil,"Need valid connector id"
	end
	local conn = cnvobj.drawn.conn
	for i = 1,#conn do
		if conn[i].id == connID then
			return conn[i]
		end
	end
	return nil,"No connector found"
end

-- Function to return the list of all connectors and at the vicinity measured by res. res=0 means x,y should be on the connector
-- If res is not given then it is taken as the minimum of grid_x/2 and grid_y/2
-- Returns the list of all the connectors
-- Also returns a list of tables containing more information. Each table is:
--[[
{
	conn = <integer>,	-- index of the connector in cnvobj.drawn.conn
	seg = {				-- array of indices of segments that were found on x,y for the connector
		<integer>,
		<integer>,
		...
	}
}
]]
getConnFromXY = function(cnvobj,x,y,res)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	local conns = cnvobj.drawn.conn
	if #conns == 0 then
		return {},{}
	end
	res = res or floor(min(cnvobj.grid.grid_x,cnvobj.grid.grid_y)/2)
	local pS = res == 0 and coorc.pointOnSegment or coorc.pointNearSegment
	local allConns = {}
	local segInfo = {}
	for i = 1,#conns do
		local segs = conns[i].segments
		local connAdded
		if #segs == 0 then
			-- No segments so the connector must be connecting 2 overlapping ports
			local prt = conns[i].port[1]
			if abs(prt.x-x) <= res and abs(prt.y-y) <= res then
				allConns[#allConns + 1] = conns[i]
				segInfo[#segInfo + 1] = {conn = i,seg = {}}
			end
		else
			for j = 1,#segs do
				if pS(segs[j].start_x, segs[j].start_y, segs[j].end_x, segs[j].end_y, x, y, res)  then
					if not connAdded then
						allConns[#allConns + 1] = conns[i]
						segInfo[#segInfo + 1] = {conn = i, seg = {j}}
						connAdded = true
					else
						segInfo[#segInfo].seg[#segInfo[#segInfo].seg + 1] = j	-- Add all segments that lie on that point
					end
				end
			end
		end
	end
	return allConns, segInfo
end

-- Function to set the object Visual attributes
--[[
For non filled objects attributes to set are: (given a table (attr) with all these keys and attributes
* Draw color(color)	- Table with RGB e.g. {127,230,111}
* Line Style(style)	- number or a table. Number should be one of M.CONTINUOUS, M.DASHED, M.DOTTED, M.DASH_DOT, M.DASH_DOT_DOT. FOr table it should be array of integers specifying line length in pixels and then space length in pixels. Pattern repeats
* Line width(width) - number for width in pixels
* Line Join style(join) - should be one of the constants M.MITER, M.BEVEL, M.ROUND
* Line Cap style (cap) - should be one of the constants M.CAPFLAT, M.CAPROUND, M.CAPSQUARE
]]
--[[
For Filled objects the attributes to be set are:
* Fill Color(color)	- Table with RGB e.g. {127,230,111}
* Background Opacity (bopa) - One of the constants M.OPAQUE, M.TRANSPARENT	
* Fill interior style (style) - One of the constants M.SOLID, M.HOLLOW, M.STIPPLE, M.HATCH, M.PATTERN
* Hatch style (hatch) (OPTIONAL) - Needed if style == M.HATCH. Must be one of the constants M.HORIZONTAL, M.VERTICAL, M.FDIAGONAL, M.BDIAGONAL, M.CROSS or M.DIAGCROSS
* Stipple style (stipple) (OPTIONAL) - Needed if style = M.STIPPLE. Should be a  wxh matrix of zeros (0) and ones (1). The zeros are mapped to the background color or are transparent, according to the background opacity attribute. The ones are mapped to the foreground color.
* Pattern style (pattern) (OPTIONAL) - Needed if style = M.PATTERN. Should be a wxh color matrix of tables with RGB numbers`
]]
-- The function does not know whether the object is filled or not. It just checks the validity of the attr table and sets it for that object.
-- num is a index for the visual attribute definition and adds it to the defaults and other items can use it as well by referring to the number. It optimizes the render function as well since it does not have to reexecute the visual attributes settings if the number is the same for the next item to draw.
-- Set num to 100 to make it unique. 100 is reserved for uniqueness
function setConnVisualAttr(cnvobj,conn,attr,num)
	local res,filled = utility.validateVisualAttr(attr)
	if not res then
		return res,filled
	end
	-- attr is valid now associate it with the object
	conn.vattr = tu.copyTable(attr,{},true)	-- Perform full recursive copy of the attributes table
	-- Set the attributes function in the visual properties table
	if filled then
		cnvobj.attributes.visualAttr[conn] = {vAttr = num, visualAttr = GUIFW.getFilledObjAttrFunc(attr)}
	else
		cnvobj.attributes.visualAttr[conn] = {vAttr = num, visualAttr = GUIFW.getNonFilledObjAttrFunc(attr)}
	end
	return true
end

function setSegVisualAttr(cnvobj,seg,attr,num)
	return setConnVisualAttr(cnvobj,seg,attr,num)
end


local function equalCoordinate(v1,v2)
	return v1.x == v2.x and v1.y == v2.y
end

-- Function to fix the order of all the items in the order table
local function fixOrder(cnvobj)
	-- Fix the order of all the items
	for i = 1,#cnvobj.drawn.order do
		cnvobj.drawn.order[i].item.order = i
	end
	return true
end

-- Function to check whether 2 line segments have the same line equation or not
-- The 1st line segment is from x1,y1 to x2,y2
-- The 2nd line segment is from x3,y3 to x4,y4
local function sameeqn(x1,y1,x2,y2,x3,y3,x4,y4)
	local seqn 
	if x1==x2 and x3==x4 and x1==x3 then
		-- equation is x = c for both lines
		seqn = true
	elseif x1~=x2 and x3~=x4 then
		-- equation x = c is not true for both lines
		-- round till 0.01 resolution
		local m1 = floor((y2-y1)/(x2-x1)*100)/100
		local m2 = floor((y4-y3)/(x4-x3)*100)/100
		-- Check slopes are equal and the y-intercept are the same
		if m1 == m2 and floor((y1-x1*m1)*100) == floor((y3-x3*m2)*100) then
			seqn = true
		end
	end
	return seqn
end

-- Function to find the dangling nodes. 
-- Dangling end point is defined as one which satisfies the following:
-- * The end point does not match the end points of any other segment or
-- * The end point matches the end point of only 1 segment with the same line equation
-- AND (if chkports is true)
-- * The end point does not lie on a port
-- It returns 2 tables s,e. Segment ith has starting node dangling if s[i] == true and has ending node dangling if e[i] == true
local function findDangling(cnvobj,segs,chkports)
	local s,e = {},{}		-- Starting and ending node dangling segments indexes
	for i = 1,#segs do
		local sx,sy,ex,ey = segs[i].start_x,segs[i].start_y,segs[i].end_x,segs[i].end_y
		local founds,founde = {c = 0},{c = 0}	-- To store the last segment that connected to the coordinates of this segment and also the count of total segments
		for j = 1,#segs do
			if j ~= i then
				local sx1,sy1,ex1,ey1 = segs[j].start_x,segs[j].start_y,segs[j].end_x,segs[j].end_y
				if sx == sx1 and sy == sy1 or sx == ex1 and sy == ey1 then
					founds.c = founds.c + 1
					founds.x1 = sx1
					founds.y1 = sy1
					founds.x2 = ex1
					founds.y2 = ey1
				end
				if ex == sx1 and ey == sy1 or ex == ex1 and ey == ey1 then
					founde.c = founde.c + 1
					founde.x1 = sx1
					founde.y1 = sy1
					founde.x2 = ex1
					founde.y2 = ey1
				end
			end
		end
		if founds.c < 2 then
			-- Starting node connects to 1 or 0 segments
			local chkPorts = true
			if founds.c == 1 then
				if not sameeqn(sx,sy,ex,ey,founds.x1,founds.y1,founds.x2,founds.y2) then
					if not chkports then
						s[i] = true
					else
						chkPorts = false
					end
				end
			end
			-- Starting node is dangling check if it connects to any port
			if chkPorts and #cnvobj:getPortFromXY(sx,sy) == 0 then
				s[i] = true		-- segment i starting point is dangling
			end
		end
		if founde.c < 2 then
			-- Ending node connects to 1 or 0 segments
			local chkPorts = true
			if founde.c == 1 then
				if not sameeqn(sx,sy,ex,ey,founde.x1,founde.y1,founde.x2,founde.y2) then
					if not chkports then
						e[i] = true
					else
						chkPorts = false
					end
				end
			end
			-- Ending node is dangling, check if it connects to any port
			if chkPorts and #cnvobj:getPortFromXY(ex,ey) == 0 then
				e[i] = true		-- segment i ending point is dangling
			end
		end
	end		-- for i = 1,#segs do ends here
	return s,e
end

-- Function to check whether segments are valid and if any segments need to be split further or merged and overlaps are removed and junctions are regenerated
-- This function does not touch the ports of the connector nor check their validity
local function repairSegAndJunc(cnvobj,conn)
	
	-- First find the dangling nodes. Note that dangling segments are the ones which may merge with other segments
	-- Dangling end point is defined as one which satisfies the following:
	-- * The end point does not match the end points of any other segment or
	-- * The end point matches the end point of only 1 segment with the same line equation
	-- AND
	-- * The end point does not lie on a port
	local segs = conn.segments
	local rm = cnvobj.rM
	local s,e = findDangling(cnvobj,segs,true)	-- find dangling with port check enabled
	-- Function to create segments given the coordinate pairs
	-- Segment is only created if its length is > 0
	-- coors is an array of coordinates. Each entry has the following table:
	-- {x1,y1,x2,y2} where x1,y1 and x2,y2 represent the ends of the segment to create
	local function createSegments(coors)
		local segs = {}
		for i =1,#coors do
			if not(coors[i][1] == coors[i][3] and coors[i][2] == coors[i][4]) then	-- check if both the end points are the same coordinate
				segs[#segs + 1] = {
					start_x = coors[i][1],
					start_y = coors[i][2],
					end_x = coors[i][3],
					end_y = coors[i][4]
				}
			end
		end
		return segs
	end

	-- Now check for overlaps of the dangling segments with others
	local i = 1
	while i <= #segs do
		-- Let A = x1,y1 and B=x2,y2. So AB is 1 line segment
		local x1,y1,x2,y2 = segs[i].start_x,segs[i].start_y,segs[i].end_x,segs[i].end_y
		local adang,bdang = s[i],e[i]
		local overlap,newSegs
		local j = 1
		while j <= #segs do
			if i ~= j then
				-- Let C=x3,y3 and D=x4,y4. So CD is 2nd line segment
				local x3,y3,x4,y4 = segs[j].start_x,segs[j].start_y,segs[j].end_x,segs[j].end_y
				local cdang,ddang = s[j],e[j]
				-- Check whether the 2 line segments have the same line equation
				if sameeqn(x1,y1,x2,y2,x3,y3,x4,y4) then
					overlap = j		-- Assume they overlap
					-- There are 8 overlapping cases and 4 non overlapping cases
					--[[
					1. (no overlap)
								A-----------B
					C------D	
					2. (overlap) The merge is 3 segments CA, AD and DB. If A and D are dangling then merged is CB. If A is dangling then merged is CD, DB. If D is dangling then merged is CA, AB
						A-----------B
					C------D	
					3. (overlap) The merge is 3 segments AC CD and DB. If C and D are dangling then merged is AB. If C is dangling then merged are AD and DB. If D is dangling then merged are AC and CB
					  A-----------B
						C------D	
					4. (overlap) The merge is 3 segments AC, CB and BD. If B and C are dangling then merged is AD. If C is dangling then merged is AB, BD. If B is dangling then merged are AC and CD
					  A-----------B
							  C------D	
					5. (no overlap)
						A-----------B
										C------D	
					6. (overlap) The merge is 3 segments CA, AB and BD. If A and B are dangling then merged is CD. If A is dangling then merged are CB and BD. If B is dangling then merged are CA and AD
					  C-----------D
						A------B	
					7. (no overlap)
								A-----------B
					D------C	
					8. (overlap) The merge is 3 segments DA, AC and CB. If A and C are dangling then merged is DB. If A is dangling then merged is DC and CB. If C is dangling then merged is DA and AB
						A-----------B
					D------C	
					9. (overlap) The merge is 3 segments AC, CD and DB. If C and D are dangling then merged is AB. If D is dangling then merged are AC and CB. If C is dangling then merged are AD and DB
					  A-----------B
						D------C	
					10. (overlap) The merge is 3 segments AD, DB and BC. If B and D are dangling then merged is AC. If B is dangling then merged are AD and DC. If D is dangling then mergedf are AB and BC
					  A-----------B
							  D------C	
					11. (no overlap)
						A-----------B
										D------C
					12. (overlap) The merge is 3 segments DA, AB and BC. If A and B are dangling then merged is DC. If A is dangling then merged are DB and BC. If B is dangling then merged are DA and AC
					  D-----------C
						A------B	
					
					]]
					if coorc.pointOnSegment(x1,y1,x2,y2,x3,y3) then	
						-- C lies on AB - Cases 3,4,8,9
						if coorc.pointOnSegment(x1,y1,x2,y2,x4,y4) then
							-- D lies on AB - Cases 3 and 9
							if coorc.pointOnSegment(x1,y1,x4,y4,x3,y3) then
								-- C lies on AD - Case 3
					--[[
					3. (overlap) The merge is 3 segments AC CD and DB. If C and D are dangling then merged is AB. If C is dangling then merged are AD and DB. If D is dangling then merged are AC and CB
					  A-----------B
						C------D	]]
								if cdang and ddang then
									newSegs = {
										segs[i]		-- Only AB is the segment
									}
								elseif cdang then
									newSegs = createSegments({
											{x1,y1,x4,y4},	-- AD
											{x4,y4,x2,y2},	-- DB
										})
								elseif ddang then
									newSegs = createSegments({
											{x1,y1,x3,y3},	-- AC
											{x3,y3,x2,y2},	-- CB
										})
								else
									newSegs = createSegments({
											{x1,y1,x3,y3},	-- AC
											{x3,y3,x4,y4},	-- CD
											{x4,y4,x2,y2},	-- DB
										})
								end
							else
								-- C does not lie on AD - Case 9
					--[[
					9. (overlap) The merge is 3 segments AD, DC and CB. If C and D are dangling then merged is AB. If D is dangling then merged are AC and CB. If C is dangling then merged are AD and DB
					  A-----------B
						D------C	]]
								if cdang and ddang then
									newSegs = {
										segs[i]		-- Only AB is the segment
									}
								elseif cdang then
									newSegs = createSegments({
											{x1,y1,x4,y4},	-- AD
											{x4,y4,x2,y2},	-- DB
										})
								elseif ddang then
									newSegs = createSegments({
											{x1,y1,x3,y3},	-- AC
											{x3,y3,x2,y2},	-- CB
										})
								else
									newSegs = createSegments({
											{x1,y1,x4,y4},	-- AD
											{x4,y4,x3,y3},	-- DC
											{x3,y3,x2,y2},	-- CB
										})
								end						
							end
						else
							-- C lies on AB but not D- Cases 4 and 8
							if coorc.pointOnSegment(x1,y1,x4,y4,x2,y2) then
								-- B lies on AD - Case 4
					--[[
					4. (overlap) The merge is 3 segments AC, CB and BD. If B and C are dangling then merged is AD. If C is dangling then merged is AB, BD. If B is dangling then merged are AC and CD
					  A-----------B
							  C------D	]]
								if cdang and bdang then
									newSegs = createSegments({
											{x1,y1,x4,y4},	-- AD										
										})
								elseif cdang then
									newSegs = createSegments({
											{x1,y1,x2,y2},	-- AB
											{x2,y2,x4,y4},	-- BD
										})
								elseif bdang then
									newSegs = createSegments({
											{x1,y1,x3,y3},	-- AC
											{x3,y3,x4,y4},	-- CD
										})
								else
									if x3==x2 and y3==y3 then
										-- CB is 0 so the segments won't change
										overlap=false
									else
										newSegs = createSegments({
												{x1,y1,x3,y3},	-- AC
												{x3,y3,x2,y2},	-- CB
												{x2,y2,x4,y4},	-- BD
											})
									end
								end						
							else
								-- B does not lie on AD - Case 8
					--[[
					8. (overlap) The merge is 3 segments DA, AC and CB. If A and C are dangling then merged is DB. If A is dangling then merged is DC and CB. If C is dangling then merged is DA and AB
						A-----------B
					D------C	]]
								if cdang and adang then
									newSegs = createSegments({
											{x4,y4,x2,y2},	-- AD										
										})
								elseif cdang then
									newSegs = createSegments({
											{x4,y4,x1,y1},	-- DA
											{x1,y1,x2,y2},	-- AB
										})
								elseif adang then
									newSegs = createSegments({
											{x4,y4,x3,y3},	-- DC
											{x3,y3,x2,y2},	-- CB
										})
								else
									if x1==x3 and y1==y3 then
										-- AC is 0 so segments don't change
										overlap = false
									else
										newSegs = createSegments({
												{x4,y4,x1,y1},	-- DA
												{x1,y1,x3,y3},	-- AC
												{x3,y3,x2,y2},	-- CB
											})
									end
								end						
							end		-- if B lies on AD check
						end		-- if D lies on AB check					
					else	-- if C lies on AB check
						-- C does not lie on AB - Cases 1,2,5,6,7,10,11,12
						if coorc.pointOnSegment(x1,y1,x2,y2,x4,y4) then
							-- D lies on AB - Cases 2 and 10
							if coorc.pointOnSegment(x1,y1,x3,y3,x2,y2) then
								-- B lies on AC	-- Case 10
					--[[
					10. (overlap) The merge is 3 segments AD, DB and BC. If B and D are dangling then merged is AC. If B is dangling then merged are AD and DC. If D is dangling then merged are AB and BC
					  A-----------B
							  D------C	]]
								if bdang and ddang then
									newSegs = createSegments({
											{x1,y1,x3,y3},	-- AC										
										})
								elseif bdang then
									newSegs = createSegments({
											{x1,y1,x4,y4},	-- AD
											{x4,y4,x3,y3},	-- DC
										})
								elseif ddang then
									newSegs = createSegments({
											{x1,y1,x2,y2},	-- AB
											{x2,y2,x3,y3},	-- BC
										})
								else
									if x4==x2 and y4==y2 then
										-- DB is 0 so the segments don't change
										overlap = false
									else
										newSegs = createSegments({
												{x1,y1,x4,y4},	-- AD
												{x4,y4,x2,y2},	-- DB
												{x2,y2,x3,y3},	-- BC
											})
									end
								end						
							else
								-- B does not lie on AC	- Case 2
					--[[
					2. (overlap) The merge is 3 segments CA, AD and DB. If A and D are dangling then merged is CB. If A is dangling then merged is CD, DB. If D is dangling then merged is CA, AB
						A-----------B
					C------D	]]
								if adang and ddang then
									newSegs = createSegments({
											{x3,y3,x2,y2},	-- CB										
										})
								elseif adang then
									newSegs = createSegments({
											{x3,y3,x4,y4},	-- CD
											{x4,y4,x2,y2},	-- DB
										})
								elseif ddang then
									newSegs = createSegments({
											{x3,y3,x1,y1},	-- CA
											{x1,y1,x2,y2},	-- AB
										})
								else
									if x1==x4 and y1==y4 then
										-- AD is 0 so the segments don't change
										overlap = false
									else
										newSegs = createSegments({
												{x3,y3,x1,y1},	-- CA
												{x1,y1,x4,y4},	-- AD
												{x4,y4,x2,y2},	-- DB
											})
									end
								end											
							end		-- if B lies on AC check
						else	-- if D lies on AB check
							-- D does not lie on AB nor does C - Cases 1,5,6,7,11,12
							if coorc.pointOnSegment(x3,y3,x4,y4,x1,y1) then
								-- A lies on CD then - Cases 6 and 12
								if coorc.pointOnSegment(x3,y3,x2,y2,x1,y1) then
									-- A lies on CB - Case 6
					--[[
					6. (overlap) The merge is 3 segments CA, AB and BD. If A and B are dangling then merged is CD. If A is dangling then merged are CB and BD. If B is dangling then merged are CA and AD
					  C-----------D
						A------B	]]
									if adang and bdang then
										newSegs = {
											segs[j]				-- CD
										}
									elseif adang then
										newSegs = createSegments({
												{x3,y3,x2,y2},	-- CB
												{x2,y2,x4,y4},	-- BD
											})
									elseif bdang then
										newSegs = createSegments({
												{x3,y3,x1,y1},	-- CA
												{x1,y1,x4,y4},	-- AD
											})
									else
										newSegs = createSegments({
												{x3,y3,x1,y1},	-- CA
												{x1,y1,x2,y2},	-- AB
												{x2,y2,x4,y4},	-- BD
											})
									end											
								else
									-- A does not lie on CB - Case 12
					--[[
					12. (overlap) The merge is 3 segments DA, AB and BC. If A and B are dangling then merged is DC. If A is dangling then merged are DB and BC. If B is dangling then merged are DA and AC
					  D-----------C
						A------B	]]
									if adang and bdang then
										newSegs = createSegments({
												{x4,y4,x3,y3},	-- DC										
											})
									elseif adang then
										newSegs = createSegments({
												{x4,y4,x2,y2},	-- DB
												{x2,y2,x3,y3},	-- BC
											})
									elseif bdang then
										newSegs = createSegments({
												{x4,y4,x1,y1},	-- DA
												{x1,y1,x3,y3},	-- AC
											})
									else
										newSegs = createSegments({
												{x4,y4,x1,y1},	-- DA
												{x1,y1,x2,y2},	-- AB
												{x2,y2,x3,y3},	-- BC
											})
									end											
								end
							else
								-- Cases 1,5,7,11 - no overlap
								overlap = false
							end
						end	-- if check D lies on AB ends
					end		-- if check C lies on AB ends
				end		-- if sameeqn then ends here
			end		-- if i ~= j then ends here
			if overlap then
				-- Handle the merge of the new segments here
				local pos
				-- Remove from routing matrix
				rm:removeSegment(segs[i])
				rm:removeSegment(segs[j])
				if i > j then
					table.remove(segs,i)
					table.remove(segs,j)
					pos = i - 1
					i = i - 1  	-- to compensate for the i increment
				else
					table.remove(segs,j)
					table.remove(segs,i)
					pos = i
				end
				-- Insert all the new segments at the pos position
				for k = #newSegs,1,-1 do
					rm:addSegment(newSegs[k],newSegs[k].start_x,newSegs[k].start_y,newSegs[k].end_x,newSegs[k].end_y)
					table.insert(segs,pos,newSegs[k])
				end
				-- Update the dangling nodes
				s,e = findDangling(cnvobj,segs,true)	-- find dangling with port check enabled
				x1,y1,x2,y2 = segs[i].start_x,segs[i].start_y,segs[i].end_x,segs[i].end_y
				adang,bdang = s[i],e[i]
				j = 0	-- Reset j to run with all segments again
				overlap = nil
			end
			j = j + 1
		end		-- while j <= #segs ends
		i = i + 1
	end		-- for i = 1,#segs do ends
	-- Now all merging of the overlaps is done
	-- Now check if any segment needs to split up
	-- The loop below handles the case then 2 segments touch but not of the same equation
	-- So they don't overlap. For example 2 segments making a T. The top of the T would need to split into 2 segments, i.e. a T should be always made of 3 segments and a junction
	local donecoor = {}		-- Store coordinates of the end points of all the segments and also indicate how many segments connect there
	for i = 1,#segs do
		-- Do the starting coordinate
		local X,Y = segs[i].start_x,segs[i].start_y
		if not donecoor[X] then
			donecoor[X] = {}
		end
		if not donecoor[X][Y] then
			donecoor[X][Y] = 1
			local conns,segmts = getConnFromXY(cnvobj,X,Y,0)	-- 0 resolution check
			-- We should just have 1 connector here ideally but if not lets find the index for this connector
			local l
			for j = 1,#conns do
				if conns[j] == conn then
					l = j 
					break
				end
			end
			-- Sort the segments in ascending order
			table.sort(segmts[l].seg)
			-- Iterate over all the segments at this point
			for k = #segmts[l].seg,1,-1 do		-- Iterate from the highest segment number so that if segment is inserted then index of lower segments do not change
				local j = segmts[l].seg[k]	-- Contains the segment number where the point X,Y lies
				-- Check whether any of the end points match X,Y (allSegs[i].x,allSegs[i].y)
				if not(segs[j].start_x == X and segs[j].start_y == Y or segs[j].end_x == X and segs[j].end_y == Y) then 
					-- The point X,Y lies somewhere on this segment in between so split the segment into 2
					rm:removeSegment(segs[j])
					table.insert(segs,j+1,{
						start_x = X,
						start_y = Y,
						end_x = segs[j].end_x,
						end_y = segs[j].end_y
					})
					rm:addSegment(segs[j+1],segs[j+1].start_x,segs[j+1].start_y,segs[j+1].end_x,segs[j+1].end_y)
					segs[j].end_x = X
					segs[j].end_y = Y
					rm:addSegment(segs[j],segs[j].start_x,segs[j].start_y,segs[j].end_x,segs[j].end_y)
					donecoor[X][Y] = donecoor[X][Y] + 2		-- 2 more end points now added at this point
				end
			end
		else
			donecoor[X][Y] = donecoor[X][Y] + 1	-- Add to the number of segments connected at this point
		end
		-- Do the end coordinate
		X,Y = segs[i].end_x,segs[i].end_y
		if not donecoor[X] then
			donecoor[X] = {}
		end
		if not donecoor[X][Y] then
			donecoor[X][Y] = 1
			local conns,segmts = getConnFromXY(cnvobj,X,Y,0)	-- 0 resolution check
			-- We should just have 1 connector here ideally but if not lets find the index for this connector
			local l
			for j = 1,#conns do
				if conns[j] == conn then
					l = j 
					break
				end
			end
			-- Sort the segments in ascending order
			table.sort(segmts[l].seg)
			-- Iterate over all the segments at this point
			for k = #segmts[l].seg,1,-1 do		-- Iterate from the highest segment number so that if segment is inserted then index of lower segments do not change
				local j = segmts[l].seg[k]	-- Contains the segment number where the point X,Y lies
				-- Check whether any of the end points match X,Y (allSegs[i].x,allSegs[i].y)
				if not(segs[j].start_x == X and segs[j].start_y == Y or segs[j].end_x == X and segs[j].end_y == Y) then 
					-- The point X,Y lies somewhere on this segment in between so split the segment into 2
					rm:removeSegment(segs[j])
					table.insert(segs,j+1,{
						start_x = X,
						start_y = Y,
						end_x = segs[j].end_x,
						end_y = segs[j].end_y
					})
					rm:addSegment(segs[j+1],segs[j+1].start_x,segs[j+1].start_y,segs[j+1].end_x,segs[j+1].end_y)
					segs[j].end_x = X
					segs[j].end_y = Y
					rm:addSegment(segs[j],segs[j].start_x,segs[j].start_y,segs[j].end_x,segs[j].end_y)
					donecoor[X][Y] = donecoor[X][Y] + 2		-- 2 more end points now added at this point
				end
			end
		else
			donecoor[X][Y] = donecoor[X][Y] + 1	-- Add to the number of segments connected at this point
		end		
	end
	-- Figure out the junctions
	local j = {}
	for k,v in pairs(donecoor) do
		for n,m in pairs(v) do
			if m > 2 then
				j[#j + 1] = {x=k,y=n}
			end
		end
	end
	conn.junction = j
	return true
end		-- function repairSegAndJunc ends here

do 
	-- Function to look at the given connector conn and short an merge it with any other connector its segments end points touch
	-- All the touching connectors are merged into 1 connector and all data structures updated appropriately
	-- Order of the resulting connector will be the highest order of all the merged conectors
	-- The connector ID of the resultant connector is the highest connector ID of all the connectors
	-- Returns the final merged connector together with the list of connector ids that were merged (including the merged connector - which is at the last spot in the list)
	local shortAndMergeConnector = function(cnvobj,conn)
		local coor = {}
		-- collect all the segment end points
		for i = 1,#conn.segments do
			tu.mergeArrays({
					{
						x = conn.segments[i].start_x,
						y = conn.segments[i].start_y
					},
					{
						x = conn.segments[i].end_x,
						y = conn.segments[i].end_y
					}				
				},coor,nil,equalCoordinate)
		end
		-- Get all the connectors on the given coor
		local allSegs = {}		-- To store the list of all segs structures returned for all coordinates in coor. A segs structure is one returned by getConnFromXY as the second argument where it has 2 keys: 'conn' contains the index of the connector at X,Y in the cnvobj.drawn.conn array and 'seg' key contains the array of indexes of the segments of that connector which are at X,Y coordinate
		for i = 1,#coor do
			local allConns,segs = getConnFromXY(cnvobj,coor[i].x,coor[i].y,0)	-- 0 resolution check
			tu.mergeArrays(segs,allSegs,nil,function(one,two)
					return one.conn == two.conn
				end)	-- Just collect the unique connectors
		end		-- for i = 1,#coor ends here
		-- Now allSegs has data about all the connectors that are present at coordinates in coor. It also has some segment numbers (not all) but they are not needed or used.
		-- Check if more than one connector in allSegs
		if #allSegs == 1 then
			-- only 1 connector and nothing to merge
			return cnvobj.drawn.conn[allSegs[1].conn],{cnvobj.drawn.conn[allSegs[1].conn].id}
		end
		-- Sort allSegs with descending connector index so the previous index is not affected when the connector is merged and deleted
		table.sort(allSegs,function(one,two)
				return one.conn > two.conn		
			end)	-- Now we need to see whether we need to split a segment and which new junctions to create
		local connM = cnvobj.drawn.conn[allSegs[#allSegs].conn]		-- The master connector where all connectors are merged (Taken as last one in allSegs since that will have the lowest index all others with higher indexes will be removed and connM index will not be affected
		local rm = cnvobj.rM
		-- The destination arrays
		local segTableD = connM.segments
		local portD = connM.port
		local juncD = connM.junction
		-- All connector data structure
		local conns = cnvobj.drawn.conn
		local maxOrder = connM.order		-- To store the maximum order of all the connectors
		local orders = {maxOrder}	-- Store the orders of all the connectors since they need to be removed from the orders array and only 1 placed finally
		for i = 1,#allSegs-1 do	-- Loop through all except the master connector
			orders[#orders + 1] = conns[allSegs[i].conn].order		-- Store the order
			if conns[allSegs[i].conn].order > maxOrder then
				maxOrder = conns[allSegs[i].conn].order				-- Get the max order of all the connectors which will be used for the master connector
			end
			-- Copy the segments over
			local segTableS = conns[allSegs[i].conn].segments
			for i = 1,#segTableS do
				local one = segTableS[i]
				for j = 1,#segTableD do
					local two = segTableD[j]
					local found
					if (one.start_x == two.start_x and one.start_y == two.start_y and
					  one.end_x == two.end_x and one.end_y == two.end_y) or
					  (one.start_x == two.end_x and one.start_y == two.end_y and
					  one.end_x == two.start_x and one.end_y == two.start_y) then
						-- The segments are the same line so it won't be added to segTableD and we will remove it from the routing matrix
						rm:removeSegment(one)
						found = true
						break
					end
				end
				if not found then
					segTableD[#segTableD + 1] = one
				end
			end
			--[[
			tu.mergeArrays(segTableS,segTableD,nil,function(one,two)	-- Function to check if one and two are equivalent segments
					return (one.start_x == two.start_x and one.start_y == two.start_y and
						one.end_x == two.end_x and one.end_y == two.end_y) or
						(one.start_x == two.end_x and one.start_y == two.end_y and
						one.end_x == two.start_x and one.end_y == two.start_y)
				end)
			]]
			-- Copy and update the ports
			local portS = conns[allSegs[i].conn].port
			for k = 1,#portS do
				-- Check if this port already exists
				if not tu.inArray(portD,portS[k]) then
					portD[#portD + 1] = portS[k]
					-- Update the port to refer to the connM connector
					portS[k].conn[#portS[k].conn + 1] = connM
				end
				-- Remove the conns[allSegs[i].conn] connector from the portS[i].conn array since that connector is going to go away
				for j = 1,#portS[k].conn do
					if portS[k].conn[j] == conns[allSegs[i].conn] then
						table.remove(portS[k].conn,j)
						break
					end
				end
			end
			-- Copy the junctions
			local juncS = conns[allSegs[i].conn].junction
			tu.mergeArrays(juncS,juncD,nil,equalCoordinate)
			-- Copy visual attributes if any
			local  vattrS = conns[allSegs[i].conn].vattr
			if vattrS and not connM.vattr then
				connM.vattr = tu.copyTable(vattrS,{},true)
				cnvobj.attributes.visualAttr[connM] = cnvobj.attributes.visualAttr[conns[allSegs[i].conn]]
			end
		end		-- for i = 1,#allSegs-1 do	 ends 
		-- Create a list of connector IDs that were merged
		local mergedIDs = {}
		-- Remove all the merged connectors from the connectors array
		for i = 1,#allSegs-1 do
			mergedIDs[#mergedIDs + 1] = conns[allSegs[i].conn].id
			table.remove(conns,allSegs[i].conn)
		end
		mergedIDs[#mergedIDs + 1] = connM.id
		-- Remove all the merged connectors from the order array
		table.sort(orders)
		for i = #orders,1,-1 do
			table.remove(cnvobj.drawn.order,orders[i])
		end
		-- Set the order to the highest
		connM.order = maxOrder
		-- Put the connector at the right place in the order
		table.insert(cnvobj.drawn.order,maxOrder-#orders + 1,{type="connector",item=connM})
		-- Fix the order of all the items
		fixOrder(cnvobj)
		
		return connM,mergedIDs	-- Merging done
	end

	-- Function to short and merge a list of connectors. It calls shortAndMergeConnector repeatedly and takes care if the current connector was already merged to a previous connector then it does it again to see if the it does any more merging
	-- Returns the full merge map which shows all the merging mappings that happenned
	function shortAndMergeConnectors(cnvobj,conns)
		if not cnvobj or type(cnvobj) ~= "table" then
			return nil,"Not a valid lua-gl object"
		end
		local mergeMap = {}
		for i = 1,#conns do
			-- First check the merged map if this connector was already done
			local done
			for j = 1,#mergeMap do
				for k = 1,#mergeMap[j][2] do
					if mergeMap[j][2][k] == conns[i].id then
						done = true
						break
					end
				end
				if done then break end
			end
			if not done then
				mergeMap[#mergeMap + 1] = {shortAndMergeConnector(cnvobj,conns[i])}
				while #mergeMap[#mergeMap][2] > 1 do
					mergeMap[#mergeMap + 1] = {shortAndMergeConnector(cnvobj,mergeMap[#mergeMap][1])}
				end
			end			
		end
		-- Now run repairSegAndJunc on all the merged connectors
		-- Go through mergeMap and run repairSegAndJunc only for those connector structures which are the resulting merged connectors
		for i = 1,#mergeMap do
			local found
			for j = i + 1,#mergeMap do
				for k = 1,#mergeMap[j][2] do
					if mergeMap[j][2][k] == mergeMap[i][1].id then
						found = true
						break
					end
				end
				if found then break end
			end
			if not found then
				repairSegAndJunc(cnvobj,mergeMap[i][1])
			end
		end
		return mergeMap
	end
end

-- Function to split a connector into N connectors at the given Coordinate. If the coordinate is in the middle of a segment then the segment is split first and then the connector is split
-- The result will be N (>1) connectors that are returned as an array 
-- The order of the connectors is not set nor they are put in the order array
-- The connectors are also not placed in the cnvobj.drawn.conn array nor the given connector removed from it
-- The original connector is not modified but the ports it connects to has the entry for it removed
-- The function also does not check whether the ports associated with the connector are valid nor does it look for new ports that may be touching the connector. It simply divides the ports into the new resulting connectors based on their coordinates and the coordinates of the end points of the segments
-- The id of the 1st connector in the returned list is the same as that of the given connector. If the connector could not be split there will be only 1 connector in the returned list which can directly replace the given connector in the cnvobj.drawn.conn array and the order array after initializing its order key
local function splitConnectorAtCoor(cnvobj,conn,X,Y)
	-- First check if coor is in the middle of a segment. If it is then split the segment to make coor at the end
	local allConns,sgmnts = getConnFromXY(cnvobj,X,Y,0)
	local rm = cnvobj.rM	-- routing Matrix
	local segs = conn.segments
	for j = 1,#allConns do
		if allConns[j] == conn then
			-- Sort the segments in ascending order
			table.sort(sgmnts[j].seg)
			-- Check all the segments that lie on X,Y
			for l = #sgmnts[j].seg,1,-1 do
				local k = sgmnts[j].seg[l]	-- Contains the segment number where the point X,Y lies
				-- Check whether any of the end points match X,Y
				if not(segs[k].start_x == X and segs[k].start_y == Y or segs[k].end_x == X and segs[k].end_y == Y) then 
					-- The point X,Y lies somewhere on this segment in between so split the segment into 2
					rm:removeSegment(segs[k])
					table.insert(segs,k+1,{
						start_x = X,
						start_y = Y,
						end_x = segs[k].end_x,
						end_y = segs[k].end_y
					})
					rm:addSegment(segs[k+1],segs[k+1].start_x,segs[k+1].start_y,segs[k+1].end_x,segs[k+1].end_y)
					segs[k].end_x = X
					segs[k].end_y = Y
					rm:addSegment(segs[k],segs[k].start_x,segs[k].start_y,segs[k].end_x,segs[k].end_y)
				end
			end
			break	-- The connector has only 1 entry in allConns as returned by getConnFromXY
		end
	end
	
	local connA = {}		-- Initialize the connector array where all the resulting connectors will be placed
	local segsDone = {}		-- Data structure to store segments in the path for each starting segment
	-- Function to find and return all segments connected to x,y in segs array ignoring segments already in segsDone
	local function findSegs(segs,x,y,segsDone)
		local list = {}
		for i = 1,#segs do
			if not segsDone[segs[i]] then
				if segs[i].start_x == x and segs[i].start_y == y or segs[i].end_x == x and segs[i].end_y == y then
					list[#list + 1] = segs[i]
				end
			end
		end
		return list
	end
	-- Get all the segments connected to X,Y
	local csegs = findSegs(segs,X,Y,{})	-- Get the segments connected to X,Y
	local function createConnector(j,endPoints)
		local cn = {
			id = nil,
			order = nil,
			segments = {},
			port = {},
			junction = {}
		}
		if j == 1 then
			cn.id = conn.id
		else
			cn.id = "C"..tostring(cnvobj.drawn.conn.ids + 1)
			cnvobj.drawn.conn.ids = cnvobj.drawn.conn.ids + 1
		end
		-- Fill in the segments
		for k,v in pairs(segsDone[j]) do
			cn.segments[#cn.segments + 1] = k
		end
		-- Fill in the ports
		for i = 1,#conn.port do
			if endPoints[conn.port[i].x] and endPoints[conn.port[i].x][conn.port[i].y] then
				-- this port goes in this new connector
				cn.port[#cn.port + 1] = conn.port[i]
				-- Remove conn from conn.port[i] and add cn
				local pconn = conn.port[i].conn
				for k = 1,#pconn do
					if pconn[k] == conn then
						table.remove(pconn,k)
						break
					end
				end
				pconn[#pconn + 1] = cn
			end
		end
		-- Now regenerate the junctions
		local jn = {}
		for x,yt in pairs(endPoints) do
			for y,num in pairs(yt) do
				if num > 2 then	-- greater than 2 segments were at this point
					jn[#jn + 1] = {x=x,y=y}
				end
			end
		end
		cn.junction = jn
		-- Not copy the vattr table if any
		if conn.vattr then
			cn.vattr = tu.copyTable(conn.vattr,{},true)
			cnvobj.attributes.visualAttr[cn] = cnvobj.attributes.visualAttr[conn]
		end
		return cn
	end
	-- Now from each of the segments found check if there is a path through the segments to the ends of the other segments in csegs
	local function addEndPoint(endPoints,x,y)
		if not endPoints[x] then
			endPoints[x] = {}
		end
		if not endPoints[x][y] then
			endPoints[x][y] = 1
		else
			endPoints[x][y] = endPoints[x][y] + 1
		end		
	end
	
	local j = 1
	while j <= #csegs do
		local segPath = {}		-- To store the path of segments taken while searching for a path to coordinates ex and ey
		local endPoints = {}		-- To collect all the endpoint coordinates of segments collected in segsDone
		addEndPoint(endPoints,X,Y)
		segsDone[j] = {}
		segsDone[j][csegs[j]] = true	-- Add the 1st segment as traversed
		if csegs[j].start_x == X and csegs[j].start_y == Y then
			segPath[1] = {			-- 1st step in the path initialized
				x = csegs[j].end_x,
				y = csegs[j].end_y,
				i = 0		-- segment index that will be traversed
			}
		else
			segPath[1] = {			-- 1st step in the path initialized
				x = csegs[j].start_x,
				y = csegs[j].start_y,
				i = 0		-- segment index that will be traversed
			}			
		end
		addEndPoint(endPoints,segPath[1].x,segPath[1].y)
		if #cnvobj:getPortFromXY(segPath[1].x,segPath[1].y) == 0 then	 -- If there is a port here then path ends here for this segment
			segPath[1].segs = findSegs(segs,segPath[1].x,segPath[1].y,segsDone[j])	-- get all segments connected at this step
		else
			segPath[1].segs = {}
		end
		-- Create the segment traversal algorithm (i is the step index corresponding to the index of segPath)
		local i = 1
		while i > 0 do
			--[=[
			-- No need to remove the segment from segsDone since traversing through there did not yield the path
			if segs[segPath[i].i] then
				-- remove the last segment from the 
				segsDone[segs[segPath[i].i]] = nil
			end
			]=]
			segPath[i].i = segPath[i].i + 1
			if segPath[i].i > #segPath[i].segs then
				-- This level is exhausted. Go up a level and look at the next segment
				table.remove(segPath,i)	-- Remove this step
				i = i - 1
			else
				-- We have segments that can be traversed
				local sgmnt = segPath[i].segs[segPath[i].i]
				-- Check if this path is already traversed
				if not segsDone[j][sgmnt] then
					local nxt_x,nxt_y
					if sgmnt.start_x == segPath[i].x and sgmnt.start_y == segPath[i].y then
						nxt_x = sgmnt.end_x
						nxt_y = sgmnt.end_y
					else
						nxt_x = sgmnt.start_x
						nxt_y = sgmnt.start_y
					end
					
					-- Traverse this segment
					segsDone[j][sgmnt] = true
					-- Check whether the end point (nxt_x,nxt_y) of this segment lands on a port then this path ends here
					if #cnvobj:getPortFromXY(nxt_x,nxt_y) == 0 then	 -- If there is a port here then path ends here for this segment
						-- Check the end points of this new segment with the end points of other members in csegs
						local k = j + 1
						while k <= #csegs do	-- Loop through all the next segments in csegs
							local ex,ey		-- to store the end point other than X,Y
							if csegs[k].start_x == X and csegs[k].start_y == Y then
								ex,ey = csegs[k].end_x,csegs[k].end_y
							else
								ex,ey = csegs[k].start_x,csegs[k].start_y
							end
							if sgmnt.start_x == ex and sgmnt.start_y == ey or sgmnt.end_x == ex and sgmnt.end_y == ey then
								-- found the other point in the kth starting segment so segment j cannot split with segment k
								-- Add the kth segment to the segsDone structure 
								segsDone[j][csegs[k]] = true
								-- Merge the kth segment with the jth segment (remove it from the csegs table)
								table.remove(csegs,k)
								k = k - 1	-- To compensate for the removed segment
							end
							k = k + 1
						end		-- while k <= #csegs ends here
						i = i + 1
						segPath[i] = {i = 0}
						segPath[i].x = nxt_x
						segPath[i].y = nxt_y
						segPath[i].segs = findSegs(segs,segPath[i].x,segPath[i].y,segsDone[j])
					end		-- if #cnvobj:getPortFromXY(nxt_x,nxt_y) == 0 then ends
					-- Store the endPoints
					addEndPoint(endPoints,sgmnt.end_x,sgmnt.end_y)
					addEndPoint(endPoints,sgmnt.start_x,sgmnt.start_y)
				end		-- if not segsDone[j][sgmnt] ends here
			end		-- if segPath[i].i > #segPath[i].segs ends here
		end		-- while i > 0 ends here
		-- Now segsDone has all the segments that connect to the csegs[j] starting connector. So we can form 1 connector using these
		connA[#connA + 1] = createConnector(j,endPoints)
		--[=[
		{
			id = nil,
			order = nil,
			segments = {},
			port = {},
			junction = {}
		}
		if j == 1 then
			connA[#connA].id = conn.id
		else
			connA[#connA].id = "C"..tostring(cnvobj.drawn.conn.ids + 1)
			cnvobj.drawn.conn.ids = cnvobj.drawn.conn.ids + 1
		end
		-- Fill in the segments
		for k,v in pairs(segsDone[j]) do
			connA[#connA].segments[#connA[#connA].segments + 1] = k
		end
		-- Fill in the ports
		for i = 1,#conn.port do
			if endPoints[conn.port[i].x] and endPoints[conn.port[i].x][conn.port[i].y] then
				-- this port goes in this new connector
				connA[#connA].port[#connA[#connA].port + 1] = conn.port[i]
				-- Remove conn from conn.port[i] and add connA[#connA]
				local pconn = conn.port[i].conn
				for k = 1,#pconn do
					if pconn[k] == conn then
						table.remove(pconn,k)
						break
					end
				end
				pconn[#pconn + 1] = connA[#connA]
			end
		end
		-- Now regenerate the junctions
		local jn = {}
		for x,yt in pairs(endPoints) do
			for y,num in pairs(yt) do
				if num > 2 then	-- greater than 2 segments were at this point
					jn[#jn + 1] = {x=x,y=y}
				end
			end
		end
		connA[#connA].junction = jn
		-- Not copy the vattr table if any
		if conn.vattr then
			connA[#connA].vattr = tu.copyTable(conn.vattr,{},true)
			cnvobj.attributes.visualAttr[connA[#connA]] = cnvobj.attributes.visualAttr[conn]
		end
		]=]
		j = j + 1
	end		-- while j <= #csegs do ends
	-- Check if any segments left in conn then create another connector with it
	segsDone[j] = {}
	local makeConn
	local endPoints = {}
	for i = 1,#conn.segments do
		local sgmnt = conn.segments[i]
		local found
		for k = 1,j-1 do
			if segsDone[k][sgmnt] then
				found = true
				break
			end
		end
		if not found then
			segsDone[j][sgmnt] = true
			makeConn = true
			-- Store the endPoints
			if not endPoints[sgmnt.end_x] then
				endPoints[sgmnt.end_x] = {}
			end
			if not endPoints[sgmnt.end_x][sgmnt.end_y] then
				endPoints[sgmnt.end_x][sgmnt.end_y] = 1
			else
				endPoints[sgmnt.end_x][sgmnt.end_y] = endPoints[sgmnt.end_x][sgmnt.end_y] + 1
			end
			if not endPoints[sgmnt.start_x] then
				endPoints[sgmnt.start_x] = {}
			end
			if not endPoints[sgmnt.start_x][sgmnt.start_y] then
				endPoints[sgmnt.start_x][sgmnt.start_y] = 1
			else
				endPoints[sgmnt.start_x][sgmnt.start_y] = endPoints[sgmnt.start_x][sgmnt.start_y] + 1
			end
		end
	end
	if makeConn then
		connA[#connA + 1] = createConnector(j,endPoints)
	end
	return connA
end

-- Function to check if any ports in the drawn data port array (or, if given, in the ports array) touch the given connector 'conn'. All touching ports are connected to the connector if not already done
-- if conn is not given then all connectors are processed
-- To connect the port to the connector unless the port lies on a dangling end the connector is split at the port so that the connector never crosses the port
-- If a port in ports is already connected to the connectors processed then it is first disconnected to avoid duplicating of connectors in the port data structure as described below:
-- It is best to disconnect ports from the connector before processing. Because if there is a split in the connector it creates new connectors without any ports and then it adds the port to both the connectors. The problem is if that port was connected to the original connector the port.conn array still contains the pointer to the old connector and that is not removed.
function connectOverlapPorts(cnvobj,conn,ports)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	-- Check all the ports in the drawn structure/given ports array and see if any port lies on this connector then connect to it by splitting it
	ports = ports or cnvobj.drawn.port
	local segs,k
	local all = not conn
	local splitColl = {conn}	-- Array to store all connectors that result from the split since all of them have to be processed for every port
	for i = 1,#ports do	-- Check for every port in the list
		local X,Y = ports[i].x,ports[i].y
		local allConns,sgmnts = getConnFromXY(cnvobj,X,Y,0)
		for j = 1,#allConns do
			conn = allConns[j]
			-- Check if this connector needs to be processed
			if all or tu.inArray(splitColl,allConns[j]) then	
				-- This connector lies on the port 
				
				-- From this connector disconnect ports[i] if there
				-- This is done because we may be dealing with the connector which does not have ports[i] so to make the 2 cases common remove
				-- ports[i] from the connector and then add it later
				k = tu.inArray(ports[i].conn,conn)
				if k then
					-- ports[i] was connected to conn so disconnected it
					table.remove(ports[i].conn,k)	-- remove conn from ports table
					k = tu.inArray(conn.port,ports[i])
					if k then
						-- port in the connector port table at index k
						table.remove(conn.port,k)	-- remove the port from the connector port table
					end
				end
				segs = conn.segments
				-- Check if the port lies on a dangling node
				-- If there are more than 1 segment on this port then it cannot be a dangling segment since the connector will have to be split
				local split
				if #sgmnts[j].seg > 1 then
					split = true
				else
					-- only 1 segment is on the port
					-- Check if it is not on the end points then we would have to split the connector
					if not(segs[sgmnts[j].seg[1]].start_x == X and segs[sgmnts[j].seg[1]].start_y == Y or segs[sgmnts[j].seg[1]].end_x == X and segs[sgmnts[j].seg[1]].end_y == Y) then 
						split = true
					end
				end
				if split then
					-- Split the connector across all the segments that lie on the port
					local splitConn = splitConnectorAtCoor(cnvobj,conn,X,Y)	-- To get the list of connectors after splitting the connector at this point
					-- split also removes the reference of the connector from its ports
					-- split also places the right ports present in conn at all the split connectors
					-- Place the connectors at the spot in cnvobj.drawn.conn where conn was
					local l = sgmnts[j].conn	-- index of the connector in cnvobj.drawn.conn
					table.remove(cnvobj.drawn.conn,l)
					--[[
					-- Remove the connector reference from all its ports
					for k = 1,#conn.port do
						local m = tu.inArray(conn.port[k].conn,conn)
						table.remove(conn.port[k].conn,m)
					end
					]]
					-- Remove conn from order and place the connectors at that spot
					local ord = conn.order
					table.remove(cnvobj.drawn.order,ord)
					-- Connect the port (and ports in conn) to each of the returned connectors
					-- Note that ports[i] was already removed from conn if it was there in the beginning of the j loop above
					-- Now conn only has ports other than ports[i]
					for k = 1,#splitConn do
						-- Check if splitConn[k] connects to X,Y
						local addPort
						local spSegs = splitConn[k].segments
						for m = 1,#spSegs do
							if (spSegs[m].start_x == X and spSegs[m].start_y == Y) or
							  (spSegs[m].end_x == X and spSegs[m].end_y == Y) then
								addPort = true
								break
							end
						end
						if addPort then
							local sp = splitConn[k].port
							-- Add the port to the connector port array
							sp[#sp + 1] = ports[i]
							-- Add the connector to the port connector array
							ports[i].conn[#ports[i].conn + 1] = splitConn[k]
						end
						-- Now do this for ports in conn -- Already done in splitConnectorAtCoor
						--[[
						for m = 1,#conn.port do
							conn.port[m].conn[#conn.port[m].conn + 1] = splitConn[k]
							sp[#sp + 1] = conn.port[m]
						end]]
						-- Place the connector at the original connector spot
						table.insert(cnvobj.drawn.conn,l,splitConn[k])
						-- Place the connectors at the order spot of the original connector
						table.insert(cnvobj.drawn.order,ord,{type="connector",item=splitConn[k]})
						-- Add the splitConn connectors to the splitColl
						table.insert(splitColl,splitConn[k])
					end
					-- Fix the indexes of other items in sgmnts
					for k = 1,#sgmnts do
						if sgmnts[k].conn > l then
							-- This will have to increase by #splitConn - 1
							sgmnts[k].conn = sgmnts[k].conn + #splitConn - 1
						end
					end
					-- Fix order of all items
					fixOrder(cnvobj)
				else
					-- Just add the port to the connector
					-- Add the connector to the port
					ports[i].conn[#ports[i].conn + 1] = conn
					-- Add the port to the connector
					conn.port[#conn.port + 1] = ports[i]
				end
			end		-- if allConns[j] == conn and not tu.inArray(conn.port,ports[i]) then ends here
		end		-- for j = 1,#allConns do ends here
	end	
	return true
end

-- Function to merge each connector with other connectors it touches and then connect it to ports it touches
-- All data structures are updated
function assimilateConnList(cnvobj,connList)
	-- Check all the ports in the drawn structure and see if any port lies on this connector then connect to it
	local combinedMM = {}
	for i = 1,#connList do
		-- First check whether this connector was already merged into something else
		local found
		local connID = connList[i].id
		for j = 1,#combinedMM do
			for k = 1,#combinedMM[j] do	-- Loop through the array of merge maps
				if tu.inArray(combinedMM[j][k][2],connID) then
					found = true
					break
				end
			end
		end
		if not found then
			-- remove any overlaps in the final merged connector
			local mergeMap = shortAndMergeConnectors(cnvobj,{connList[i]})	-- Note shortAndMergeConnectors also runs repairSegAndJunc
			combinedMM[#combinedMM + 1] = mergeMap
			-- Connect overlapping ports
			connectOverlapPorts(cnvobj,mergeMap[#mergeMap][1])		
		end
	end		-- for i = 1,#connM do ends
	return true
end
-- Function to remove a connector
-- Removes all references of the connector from everywhere:
-- * cnvobj.drawn.conn
-- * cnvobj.drawn.order
-- * cnvobj.drawn.port
-- * Routing Matrix
removeConn = function(cnvobj,conn)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	-- First update the routing matrix
	local rm = cnvobj.rM
	for i = 1,#conn.segments do
		rm:removeSegment(conn.segments[i])
	end
	-- Remove the connector from the order array
	table.remove(cnvobj.drawn.order,conn.order)
	fixOrder(cnvobj)
	-- Remove references of the connector from all the ports connecting to it
	local ind
	for i = 1,#conn.port do
		ind = tu.inArray(conn.port[i].conn,conn)
		table.remove(conn.port[i].conn,ind)
	end
	-- Remove from the connectors array
	ind = tu.inArray(cnvobj.drawn.conn,conn)
	table.remove(cnvobj.drawn.conn,ind)
	-- All done!
	return true
end

-- Function just offsets the connectors (in list connL). It does not handle the port connections which have to be updated
function shiftConnList(connL,offx,offy,rm)
	for i = 1,#connL do
		for j = 1,#connL[i].segments do
			local seg = connL[i].segments[j]
			-- Move the segment coordinates with their port coordinates
			seg.start_x = seg.start_x + offx
			seg.start_y = seg.start_y + offy
			seg.end_x = seg.end_x + offx
			seg.end_y = seg.end_y + offy
			rm:removeSegment(seg)
			rm:addSegment(seg,seg.start_x,seg.start_y,seg.end_x,seg.end_y)
		end
	end		-- for i = 1,#connM do ends		
end

-- Function to disconnect all ports in the connector list
-- The prot structure as well as connector structure is updated to remove the link
disconnectAllPorts = function(connList)
	for i = 1,#connList do
		for j = 1,#connList[i].port do
			local prt = connList[i].port[j]
			table.remove(prt.conn,tu.inArray(prt.conn,connList[i]))
		end
		tu.emptyArray(connList[i].port)	-- All ports removed
	end	
	return true
end

-- Function to move a list of connectors
-- connM is a list of connectors that need to be moved
-- If offx and offy are given numbers then this will be a non interactive move
moveConn = function(cnvobj,connM,offx,offy)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	-- Check whether this is an interactive move or not
	local interactive
	if not offx or type(offx) ~= "number" then
		interactive = true
	elseif not offy or type(offy) ~= "number" then
		return nil, "Coordinates not given"
	end
	
	local rm = cnvobj.rM	
	
	-- Disconnect all ports in the connector
	disconnectAllPorts(connM)
	
	if not interactive then
		-- Take care of grid snapping
		offx,offy = cnvobj:snap(offx,offy)
		shiftConnList(connM,offx,offy,rm)
		-- Check all the ports in the drawn structure and see if any port lies on this connector then connect to it
		assimilateConnList(cnvobj,connM)
		return true
	end		-- if not interactive then ends
	
	-- Setup the interactive move operation here
	-- Set refX,refY as the mouse coordinate on the canvas
	local gx,gy = iup.GetGlobal("CURSORPOS"):match("^(%d%d*)x(%d%d*)$")	-- cursor position on screen
	local sx,sy = cnvobj.cnv.SCREENPOSITION:match("^(%d%d*),(%d%d*)$")	-- canvas origin position on screen
	local refX,refY = gx-sx,gy-sy	-- mouse position on canvas coordinates
	local oldBCB = cnvobj.cnv.button_cb
	local oldMCB = cnvobj.cnv.motion_cb
	
	-- Sort the group elements in ascending order ranking
	table.sort(connM,function(one,two) 
			return one.order < two.order
	end)
	
	-- Backup the orders of the elements to move and change their orders to display in the front
	local order = cnvobj.drawn.order
	local oldOrder = {}
	for i = 1,#connM do
		oldOrder[i] = connM[i].order
	end
	
	-- Move the last item in the list to the end. Last item because it is te one with the highest order
	local item = cnvobj.drawn.order[connM[#connM].order]
	table.remove(cnvobj.drawn.order,connM[#connM].order)
	table.insert(cnvobj.drawn.order,item)
	-- Move the rest of the items on the last position
	for i = 1,#connM-1 do
		item = cnvobj.drawn.order[connM[i].order]
		table.remove(cnvobj.drawn.order,connM[i].order)
		table.insert(cnvobj.drawn.order,#cnvobj.drawn.order,item)
	end
	-- Update the order number for all items 
	fixOrder(cnvobj)
	
	local function moveEnd()
		-- Reset the orders back
		for i = 1,#connM do
			local item = cnvobj.drawn.order[connM[i].order]
			table.remove(cnvobj.drawn.order,connM[i].order)
			table.insert(cnvobj.drawn.order,oldOrder[i],item)
		end
		-- Update the order number for all items 
		fixOrder(cnvobj)
		-- Restore the previous button_cb and motion_cb
		cnvobj.cnv.button_cb = oldBCB
		cnvobj.cnv.motion_cb = oldMCB	
		-- Check all the ports in the drawn structure and see if any port lies on this connector then connect to it
		assimilateConnList(cnvobj,connM)
		
		cnvobj.op[#cnvobj.op] = nil
		cnvobj:refresh()
	end
	
	local op = {}
	cnvobj.op[#cnvobj.op + 1] = op
	op.mode = "MOVECONN"
	op.finish = moveEnd
	op.coor1 = {x=connM[1].segments[1].start_x,y=connM[1].segments[1].start_y}	-- Initial starting coordinate of the 1st segment in the connector to serve as reference of the total movement
	op.ref = {x=refX,y=refY}
	op.connList = connM
	
	-- button_CB to handle segment dragging
	function cnvobj.cnv:button_cb(button,pressed,x,y, status)
		-- Check if any hooks need to be processed here
		cnvobj:processHooks("MOUSECLICKPRE",{button,pressed,x,y, status})
		if button == iup.BUTTON1 and pressed == 1 then
			-- End the move
			moveEnd()
		end
		-- Process any hooks 
		cnvobj:processHooks("MOUSECLICKPOST",{button,pressed,x,y, status})	
	end
	
	-- motion_cb to handle segment dragging
	function cnvobj.cnv:motion_cb(x,y,status)
		if op.mode == "MOVECONN" then
			x,y = cnvobj:snap(x-refX,y-refY)
			local offx,offy = x+op.coor1.x-connM[1].segments[1].start_x,y+op.coor1.y-connM[1].segments[1].start_y
			shiftConnList(connM,offx,offy,rm)
			cnvobj:refresh()
		end
	end
	
	return true
end

-- Function to split connectors based on the segments passed. The segments in the passed list are separated into a different connector (multiple connectors if they are not touching) and
-- the remaining segments are separated into a different connector (multiple connectors if they are not touching)
-- segList is a list of structures like this:
--[[
{
	conn = <connector structure>,	-- Connector structure to whom this segment belongs to 
	seg = <integer>					-- segment index of the connector
}
]]
-- Returns the list of connectors formed by the segments in the segList and also the list of connectors formed by the remaining segments of all the connectors
-- All data structures are updated
-- Notice that if either of the return list is passed to shortAndMergeConnectors function we will end up back with a single connector so this function in essence is an inverse of shortAndMergeConnectors
splitConnectorAtSegments = function(cnvobj,segList)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	
	local rm = cnvobj.rM
	
	-- Sort seglist by connector ID and for the same connector with descending segment index so if there are multiple segments that are being dragged for the same connector we handle them in descending order without changing the index of the next one in line
	table.sort(segList,function(one,two)
			if one.conn.id == two.conn.id then
				-- this is the same connector
				return one.seg > two.seg	-- sort with descending segment index
			else
				return one.conn.id > two.conn.id
			end
		end)
	
	-- Need to split the connector at the points which will break the connector as a result of the move
	-- We need to split every connector in the list to separate the segments being moved and not being moved into different connectors
	local connM = {}	-- List of connectors moving
	local connNM = {}	-- List of connectors not moving
	
	-- Function to check if the segment segS touches any connector segment end in connA. 
	-- If yes then it is added to that connector if not then anotehr connector is created in connA and the segment added to that
	local function addSegmentToConn(connA,segS)
		local found
		for k = 1,#connA do
			for l = 1,#connA[k].segments do
				local seg = connA[k].segments[l]
				if seg.start_x == segS.start_y and seg.start_y == segS.start_y or
				  seg.end_x == segS.start_x and seg.end_y == segS.start_y or
				  seg.start_x == segS.end_x and seg.start_y == segS.end_y or
				  seg.end_x == segS.end_x and seg.end_y == segS.end_y then
					found = true
					connA[k].segments[#connA[k].segments + 1] = tu.copyTable(segS,{},true)
					-- Add the segment to the routing Matrix
					local nseg = connA[k].segments[#connA[k].segments]
					rm:addSegment(nseg,nseg.start_x,nseg.start_y,nseg.end_x,nseg.end_y)
					break
				end
			end	-- for j = 1,#connM[k].segments ends
			if found then break end
		end	-- for k = 1,#connA do ends
		if not found then
			-- Create another connA connector here
			connA[#connA + 1] = {
				id = nil,
				order = nil,
				segments = {
					tu.copyTable(segS,{},true)
				},
				port = {},
				junction = {}
			}
			connA[#connA].id = "C"..tostring(cnvobj.drawn.conn.ids + 1)
			cnvobj.drawn.conn.ids = cnvobj.drawn.conn.ids + 1
			local nseg = connA[#connA].segments[1]
			rm:addSegment(nseg,nseg.start_x,nseg.start_y,nseg.end_x,nseg.end_y)
		end		-- if not found then ends 		
	end
	
	local cnst,cnen
	cnst = 1
	for i = 1,#segList do
		if i == #segList or segList[i+1].conn ~= segList[i].conn then	
			-- This is the last segment of this connector
			cnen = i
			local connMp,connNMp = #connM+1,#connNM+1	-- Pointers to connM and connNM to tell which items were added for this connector
			-- Now split this connector into multiple connectors
			-- 1st lets get the moving connectors
			for j = cnst,cnen do
				-- Check if this segment is touching any other segment
				addSegmentToConn(connM,segList[j].conn.segments[segList[j].seg])
				rm:removeSegment(segList[j].conn.segments[segList[j].seg])
				table.remove(segList[j].conn.segments,segList[j].seg)
			end		-- for j = cnst,cnen do ends
			-- Add the remaining segments of the connector to connNM connectors
			for j = 1,#segList[i].conn.segments do
				addSegmentToConn(connNM,segList[i].conn.segments[j])
				rm:removeSegment(segList[i].conn.segments[j])
			end
			-- Now remove the connector from the drawn connectors array and put the connectors in connM and connNM
			local pos = tu.inArray(cnvobj.drawn.conn,segList[i].conn)
			table.remove(cnvobj.drawn.conn,pos)
			-- Remove the connector from the order array as well
			pos = segList[i].conn.order
			table.remove(cnvobj.drawn.order,pos)
			-- Disconnect all ports in the connector
			disconnectAllPorts({segList[i].conn})
			for j = connMp,#connM do
				table.insert(cnvobj.drawn.conn,connM[j])	-- put connM in drawn connectors
				table.insert(cnvobj.drawn.order,pos,{		-- put connM in the order array
						type = "connector",
						item = connM[j]
					})
			end
			for j = connNMp,#connNM do
				table.insert(cnvobj.drawn.conn,connNM[j])	-- put connNM in drawn connectors
				table.insert(cnvobj.drawn.order,pos,{		-- put connNM in the order array
						type = "connector",
						item = connNM[j]
					})
			end
			cnst = i + 1
		end		-- if i == #segList or segList[i+1].conn ~= segList[i].conn ends
	end		-- for i = 1,#segList do ends here
	
	fixOrder(cnvobj)
	
	-- run connectOverlapPorts for the connectors that resulted from the segments not in segList
	for i = 1,#connNM do
		connectOverlapPorts(cnvobj,connNM[i])
	end
	
	-- run connectOverlapPorts for the connectors that resulted from the segments in segList
	for i = 1,#connM do
		connectOverlapPorts(cnvobj,connM[i])
	end
	
	return connM,connNM
end

-- Function to move a list of segments (moving implies connector connections are broken)
-- segList is a list of structures like this:
--[[
{
	conn = <connector structure>,	-- Connector structure to whom this segment belongs to 
	seg = <integer>					-- segment index of the connector
}
]]
-- If offx and offy are given numbers then this will be a non interactive move
moveSegment = function(cnvobj,segList,offx,offy)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end	
	-- Now we just need to call moveConnector
	return moveConn(cnvobj,splitConnectorAtSegments(cnvobj,segList),offx,offy)
end

-- Function to get the coordinates from where each segment in seglist would need rerouting when it is dragged. Only the starting coordinate of the routing and the offset of that coordinate from the segment end is needed. Since in the drag operation the segment is moved by a certain offset. So after the move by the offset simply generate segments from all starting coordinates in dragnodes to the new coordinates obtained by adding the drag offset and the offset stored in the dragnodes structure to reach their respective segment ends.
-- objList is a list of objects that are being dragged together.
-- If a segment is connected to a port of an object in objList then its end is not added in dragNodes since it will not need rerouting
generateRoutingStartNodes = function(cnvobj,segList,objList)
	-- Extract the list of nodes that would need re-routing as a result of the drag
	objList = objList or {}
	local dragNodes = {}
	-- dragNodes has the following structure:
	-- It is an array of tables. Each table in the array looks like this:
	--[[
	{
		x = <integer>,	-- x coordinate starting point of the route to be generated on drag
		y = <integer>,	-- y coordinate starting point of the route to be generated on drag
		conn= <connector>,	-- connector structure of the segment for whose dragnode this is
		seg = <segment>, 	-- segment structure for whose dragnode this is
		which = <string>,	-- either "start_" or "end_" to mark which coordinate of the segment this is
	}
	]]
	-- Function to return the list of segments whose one of the end point is x,y
	local function segsOnNode(conn,x,y)
		local segs = {}
		for i = 1,#conn.segments do
			if conn.segments[i].start_x == x and conn.segments[i].start_y == y then
				segs[#segs + 1] = conn.segments[i]
			elseif conn.segments[i].end_x == x and conn.segments[i].end_y == y then
				segs[#segs + 1] = conn.segments[i]
			end
		end
		return segs
	end
	local segsToRemove = {}
	-- Function to add x,y coordinate to dragNodes if all segments connected to it are not in the segList array
	local segsToAdd = {}
	local function updateDragNodes(conn,segI,which)
		local refSeg = conn.segments[segI]
		local x,y = refSeg[which.."x"],refSeg[which.."y"]
		local segs = segsOnNode(conn,x,y)
		local allSegs=true		-- to indicate if all segments in segs are in segList (at least 1 segment is in segList which coordinate is x,y)
		for j = 1,#segs do
			if not tu.inArray(segList,segs[j],function(v1,v2)
				return v1.conn.segments[v1.seg] == v2
			  end) then
				allSegs = false
				break
			end
		end
		local function equalDragNode(one,two)
			return one.x == two.x and one.y == two.y and one.offx == two.offx and one.offy == two.offy
		end
		if not allSegs or #segs == 1 then
			-- Not all segments connected to this node are in the move list. So this node will give us a point from where we need to make a routing
			-- Get the ports on this node
			local prts = PORTS.getPortFromXY(cnvobj,x,y)
			-- Check if all ports lie on objects in objList
			local allPorts = true
			for j = 1,#prts do
				if not tu.inArray(objList,prts[j],function(one,two) return one == two.obj end) then
					allPorts = false
					break
				end
			end
			-- Now check if this is a junction i.e. > 2 segments at this point. If yes then this is the routing starting point. Otherwise the other end of the segment connected to this would be the starting routing point
			if #segs > 2 or (#prts>0 and not allPorts) then 
				-- This is a junction or a ports exists here and not all of them are in objList so routing has to be done from here so this is a drag node
				tu.mergeArrays({{x = x,y = y,conn=conn,seg=refSeg,which=which}},dragNodes,false,equalDragNode)
			elseif #segs == 2 then
				-- This connects to only 1 segment and that is not in the drag list
				-- Get the other segment
				local otherSeg = segs[1]
				local ind = tu.inArray(conn.segments,otherSeg)
				if ind == segI then
					otherSeg = segs[2]
					ind = tu.inArray(conn.segments,otherSeg)
				end
				local addx,addy
				-- Get the other coordinate of the segment
				if otherSeg.start_x == x and otherSeg.start_y == y then
					addx,addy = otherSeg.end_x,otherSeg.end_y
				else
					addx,addy = otherSeg.start_x,otherSeg.start_y
				end
				-- Now either routing has to be done from addx,addy so this will be a drag node.
				-- Only case when this is not a drag node and this whole otherSeg should also be dragged is if addx,addy only connect to all segments (other than otherSeg) which are being dragged
				segs = segsOnNode(conn,addx,addy)
				allSegs = false
				for j = 1,#segs do
					if segs[j] ~= otherSeg then
						allSegs = true
						if not tu.inArray(segList,segs[j],function(v1,v2)
							return v1.conn.segments[v1.seg] == v2
						  end) then
							allSegs = false
							break
						end
					end
				end
				-- if allSegs is true then there are more segments at addx,addy other than otherSeg and all are in segList. So otherSeg should be added to segsToAdd
				if not allSegs then
					-- EITHER otherSeg is the only segment at addx,addy so it could be either dangling or have a port OR other segments on addx,addy were not all in segList
					if #segs == 1 then
						-- Check if this is a port
						-- Get the ports on this node
						prts = PORTS.getPortFromXY(cnvobj,addx,addy)
						-- Check if all ports lie on objects in objList
						local allPorts = true
						for j = 1,#prts do
							if not tu.inArray(objList,prts[j],function(one,two) return one == two.obj end) then
								allPorts = false
								break
							end
						end
						if not (#prts > 0 and allPorts) then	
							-- otherSeg connects to a port which is not in objList or it is dangling
							tu.mergeArrays({{x = addx,y = addy,conn=conn,seg=refSeg,which=which}},dragNodes,false,equalDragNode)	-- segment end at x,y will need to be routed from 
							-- Add segment to segsToRemove
							segsToRemove[#segsToRemove + 1] = {seg = otherSeg, segI = ind,conn = conn}
						else
							-- otherseg connects to ports which are in objList (objects being dragged) so we add otherSeg to the segsToAdd
							segsToAdd[#segsToAdd + 1] = {conn = conn, seg = ind}
						end
					else
						-- Not all segments connected to addx, addy are being dragged so routing from addx,addy will have to be done
						tu.mergeArrays({{x = addx,y = addy,conn=conn,seg=refSeg,which=which}},dragNodes,false,equalDragNode)	-- segment end at x,y will need to be routed from 
						-- Add segment to segsToRemove
						segsToRemove[#segsToRemove + 1] = {seg = otherSeg, segI = ind,conn = conn}
					end
				else
					-- All segments connected to addx,addy are also being dragged so add otherSeg into the list of segments to drag as well
					segsToAdd[#segsToAdd + 1] = {conn = conn, seg = ind}
				end
				
			elseif #segs == 1 then
				-- This is a dangling node. If I add this node to the dragNodes list then routing will be made from this dangling coordinate. So lets skip routing from here since this segment can be dragged wherever without routing to the dangling end original position
				-- This is also the case when there are ports here and all ports are in objList. In that case also we want no routing to happen so skip dragNodes.
			end
		end
	end
	
	local connList = {}	-- To create a list of all connectors in segList

	-- Run loop for all the segments in the segList and for each end of each segment find the drag node coordinate and any segments that need to be removed or added in the drag operation
	for i = 1,#segList do
		local conn = segList[i].conn
		local seg = conn.segments[segList[i].seg]	-- The segment that is being dragged
		updateDragNodes(conn,segList[i].seg,"start_")	-- start_x and start_y
		updateDragNodes(conn,segList[i].seg,"end_")		-- end_x and end_y
		-- Check if all segments of this connector are done
		if i == #segList or segList[i+1].conn ~= conn then
			connList[#connList + 1] = conn
		end
	end
	-- Add segsToAdd into segList
	for i = 1,#segsToAdd do
		segList[#segList + 1] = segsToAdd[i]
	end
	return dragNodes,segsToRemove,connList
end

-- Function to remove the segments in op.segsToRemove and then create the drag of the segments in op.segList and then regenerate the segments as guided by op.dragNodes
function regenSegments(cnvobj,op,rtr,js,offx,offy)
	-- Remove the segments that need to be removed for this drag step
	local segsToRemove = op.segsToRemove
	local rm = cnvobj.rM
	for i = 1,#segsToRemove do
		rm:removeSegment(segsToRemove[i].seg)
		table.remove(segsToRemove[i].conn.segments,tu.inArray(segsToRemove[i].conn.segments,segsToRemove[i].seg))
	end
	-- Move each segment
	op.segsToRemove = {}
	segsToRemove = op.segsToRemove
	local dragNodes = op.dragNodes
	local segList = op.segList
	for i = 1,#segList do
		local seg = segList[i].seg
		rm:removeSegment(seg)	-- this was already removed because is always added to segsToRemove table
		-- Move the segment
		seg.start_x = seg.start_x + offx
		seg.start_y = seg.start_y + offy
		seg.end_x = seg.end_x + offx
		seg.end_y = seg.end_y + offy
		-- Update the coordinates in the routing matrix
		rm:removeSegment(seg)	
		rm:addSegment(seg,seg.start_x,seg.start_y,seg.end_x,seg.end_y)
	end
	
	-- route segments from previous dragNodes coordinates to the new ones
	for i = 1,#dragNodes do
		local newSegs = {}
		local node = dragNodes[i]
		--print("DRAG NODES: ",offx+dragNodes[i].offx,offy+dragNodes[i].offy)
		-- Remove the segments of the connector from routing matrix to allow the routing to use the space used by the connector
		for j = 1,#node.conn.segments do
			rm:removeSegment(node.conn.segments[j])
		end
		router.generateSegments(cnvobj,node.seg[node.which.."x"],node.seg[node.which.."y"],node.x,node.y,newSegs,rtr,js) -- generateSegments updates routing matrix. Use BFS with jumping segments allowed
		-- Add the segments back in again
		for j = 1,#node.conn.segments do
			local seg = node.conn.segments[j]
			rm:addSegment(seg,seg.start_x,seg.start_y,seg.end_x,seg.end_y)
		end
		
		-- Add these segments in the connectors segment list
		for j = #newSegs,1,-1 do
			table.insert(dragNodes[i].conn.segments,newSegs[j])
			table.insert(segsToRemove,{seg=newSegs[j],conn=dragNodes[i].conn})	-- Add all the segments in segsToRemove
		end
	end
	--[[
	local stat,dump = utility.checkRM(cnvobj,true)
	if not stat then
		print("ROUTING MATRIX IN ERROR!!")
		print(dump)
	end
	]]
end

-- Function to drag a list of segments (dragging implies connector connections are maintained)
-- segList is a list of structures like this:
--[[
{
	conn = <connector structure>,	-- Connector structure to whom this segment belongs to 
	seg = <integer>					-- segment index of the connector
}
]]
-- If offx and offy are given numbers then this will be a non interactive move
-- dragRouter is the routing function to be using during dragging	-- only used if offx and offy are not given since then it will be interactive - default is cnvobj.options[0]
-- finalRouter is the routing function to be used after the drag has ended to finally route all the connectors - default is cnvobj.options.router[9]
-- jsFinal = jumpSeg parameter to be given to generateSegments functions to be used with the routing function (finalRouter) after drag has ended, default = 1
-- jsDrag = jumpSeg parameter to be given to generateSegments functions to be used with the routing function (dragRouter) durin drag operation, default = 1
-- jumpSeg parameter documentation says:
-- jumpSeg indicates whether to generate a jumping segment or not and if to set its attributes
--	= 1 generate jumping Segment and set its visual attribute to the default jumping segment visual attribute from the visualAttrBank table
-- 	= 2 generate jumping segment but don't set any special attribute
--  = false or nil then do not generate jumping segment
dragSegment = function(cnvobj,segList,offx,offy,finalRouter,jsFinal,dragRouter,jsDrag)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	-- Check whether this is an interactive move or not
	local interactive
	if not offx or type(offx) ~= "number" then
		interactive = true
	elseif not offy or type(offy) ~= "number" then
		return nil, "Coordinates not given"
	end
	
	--print("DRAG SEGMENT START")
	
	local rm = cnvobj.rM
	
	finalRouter = finalRouter or cnvobj.options.router[9]
	jsFinal = jsFinal or 1
	
	dragRouter = dragRouter or cnvobj.options.router[0]
	jsDrag = jsDrag or 2

	local dragNodes,segsToRemove,connList = generateRoutingStartNodes(cnvobj,segList)
	
	-- Sort seglist by connector ID and for the same connector with descending segment index so if there are multiple segments that are being dragged for the same connector we handle them in descending order without changing the index of the next one in line
	table.sort(segList,function(one,two)
			if one.conn.id == two.conn.id then
				-- this is the same connector
				return one.seg > two.seg	-- sort with descending segment index
			else
				return one.conn.id > two.conn.id
			end
		end)
	
	-- Sort segsToRemove in descending order of segment index
	table.sort(segsToRemove,function(one,two)
			if one.conn.id == two.conn.id then
				-- this is the same connector
				return one.segI > two.segI	-- sort with descending segment index
			else
				return one.conn.id > two.conn.id
			end
		end)
	
	-- Sort the connList elements in ascending order ranking
	table.sort(connList,function(one,two) 
			return one.order < two.order
	end)
	
	--print("Number of dragnodes = ",#dragNodes)
	-- Disconnect all ports
	disconnectAllPorts(connList)
	
	if not interactive then
		-- Take care of grid snapping
		offx,offy = cnvobj:snap(offx,offy)
		
		-- Move each segment
		for i = 1,#segList do
			local seg = segList[i].conn.segments[segList[i].seg]	-- The segment that is being dragged
			rm:removeSegment(seg)
			-- Move the segment
			seg.start_x = seg.start_x + offx
			seg.start_y = seg.start_y + offy
			seg.end_x = seg.end_x + offx
			seg.end_y = seg.end_y + offy
			rm:addSegment(seg,seg.start_x,seg.start_y,seg.end_x,seg.end_y)
		end
		-- Remove the segments that would be rerouted from routing matrix
		for i = 1,#segsToRemove do
			rm:removeSegment(segsToRemove[i].seg)
			table.remove(segsToRemove[i].conn.segments,segsToRemove[i].segI)
		end
		-- route segments from previous dragNodes coordinates to the new ones
		for i = 1,#dragNodes do
			local newSegs = {}
			local node = dragNodes[i]
			--print("DRAG NODES: ",offx+dragNodes[i].offx,offy+dragNodes[i].offy)
			-- Remove the segments of the connector from routing matrix to allow the routing to use the space used by the connector
			for j = 1,#node.conn.segments do
				rm:removeSegment(node.conn.segments[j])
			end
			router.generateSegments(cnvobj,node.seg[node.which.."x"],node.seg[node.which.."y"],node.x,node.y,newSegs,finalRouter,jsFinal) -- generateSegments updates routing matrix. Use finalrouter 
			-- Add the segments back in again
			for j = 1,#node.conn.segments do
				local seg = node.conn.segments[j]
				rm:addSegment(seg,seg.start_x,seg.start_y,seg.end_x,seg.end_y)
			end
			-- Add these segments in the connectors segment list
			for j = #newSegs,1,-1 do
				table.insert(node.conn.segments,newSegs[j])
			end
		end
		assimilateConnList(cnvobj,connList)
		return true
	end
	
	-- Convert segList and segsToRemove into segment structure pointers rather than segment Indexes
	for i = 1,#segList do
		segList[i].seg = segList[i].conn.segments[segList[i].seg]
	end
	
	for i = 1,#segsToRemove do
		segsToRemove[i].segI = nil
	end
	
	-- Setup the interactive drag operation here
	-- Set refX,refY as the mouse coordinate on the canvas
	local gx,gy = iup.GetGlobal("CURSORPOS"):match("^(%d%d*)x(%d%d*)$")	-- cursor position on screen
	local sx,sy = cnvobj.cnv.SCREENPOSITION:match("^(%d%d*),(%d%d*)$")	-- canvas origin position on screen
	local refX,refY = gx-sx,gy-sy	-- mouse position on canvas coordinates
	local oldBCB = cnvobj.cnv.button_cb
	local oldMCB = cnvobj.cnv.motion_cb
	
	-- Backup the orders of the connectors
	local oldConnOrder = {}
	for i = 1,#connList do
		oldConnOrder[i] = connList[i].order
	end
	
	-- Move the last item in the list to the end. Last item because it is the one with the highest order
	local item = cnvobj.drawn.order[connList[#connList].order]
	table.remove(cnvobj.drawn.order,connList[#connList].order)
	table.insert(cnvobj.drawn.order,item)
	-- Move the rest of the items on the last position
	for i = 1,#connList-1 do
		item = cnvobj.drawn.order[connList[i].order]
		table.remove(cnvobj.drawn.order,connList[i].order)
		table.insert(cnvobj.drawn.order,#cnvobj.drawn.order,item)
	end
	-- Update the order number for all items 
	fixOrder(cnvobj)
	
	local op = {}
	
	local function dragEnd()
		-- Reset the orders back
		-- First do the connectors
		for i = 1,#connList do
			local item = cnvobj.drawn.order[connList[i].order]
			table.remove(cnvobj.drawn.order,connList[i].order)
			table.insert(cnvobj.drawn.order,oldConnOrder[i],item)
		end
		-- Update the order number for all items 
		fixOrder(cnvobj)
		
		local gx,gy = iup.GetGlobal("CURSORPOS"):match("^(%d%d*)x(%d%d*)$")	-- cursor position on screen
		local sx,sy = cnvobj.cnv.SCREENPOSITION:match("^(%d%d*),(%d%d*)$")	-- canvas origin position on screen
		local x,y = gx-sx,gy-sy	-- mouse position on canvas coordinates
		x,y = cnvobj:snap(x-refX,y-refY)	-- Total amount mouse has moved since drag started
		local offx,offy = x+op.coor1.x-segList[1].seg.start_x,y+op.coor1.y-segList[1].seg.start_y		-- The offset to be applied now to the items being dragged

		regenSegments(cnvobj,op,finalRouter,jsFinal,offx,offy)
		-- Assimilate the modified connectors
		assimilateConnList(cnvobj,connList)
		-- Reset mode
		cnvobj.op[#cnvobj.op] = nil
		cnvobj.cnv.button_cb = oldBCB
		cnvobj.cnv.motion_cb = oldMCB
		cnvobj:refresh()
	end
		
	cnvobj.op[#cnvobj.op + 1] = op
	op.mode = "DRAGSEG"
	op.segList = segList
	op.coor1 = {x=segList[1].seg.start_x,y=segList[1].seg.start_y}	-- Initial starting coordinate of the 1st segment in the connector to serve as reference of the total movement
	op.ref = {x=refX,y=refY}
	op.finish = dragEnd
	op.dragNodes = dragNodes
	
	-- fill segsToRemove with the segments in segList
	op.segsToRemove = segsToRemove

	-- button_CB to handle segment dragging
	function cnvobj.cnv:button_cb(button,pressed,x,y, status)
		--y = cnvobj.height - y
		-- Check if any hooks need to be processed here
		cnvobj:processHooks("MOUSECLICKPRE",{button,pressed,x,y, status})
		if button == iup.BUTTON1 and pressed == 1 then
			dragEnd()
		end
		-- Process any hooks 
		cnvobj:processHooks("MOUSECLICKPOST",{button,pressed,x,y, status})	
	end
	
	-- motion_cb to handle segment dragging
	function cnvobj.cnv:motion_cb(x,y,status)
		--y = cnvobj.height - y
		--print("drag segment motion_cb")
		x,y = cnvobj:snap(x-refX,y-refY)	-- Total amount mouse has moved since drag started
		local offx,offy = x+op.coor1.x-segList[1].seg.start_x,y+op.coor1.y-segList[1].seg.start_y		-- The offset to be applied now to the items being dragged
		
		regenSegments(cnvobj,op,dragRouter,jsDrag,offx,offy)
		cnvobj:refresh()
	end
	
	return true
end

-- Function to draw a connector on the canvas
-- if segs is a table of segment coordinates then this will be a non interactive draw
-- dragRouter is the routing function to be using during dragging	-- only used if offx and offy are not given since then it will be interactive - default is cnvobj.options[9]
-- finalRouter is the routing function to be used after the drag has ended to finally route all the connectors - default is cnvobj.options.router[9]
-- jsFinal = jumpSeg parameter to be given to generateSegments functions to be used with the routing function (finalRouter) after drag has ended, default = 1
-- jsDrag = jumpSeg parameter to be given to generateSegments functions to be used with the routing function (dragRouter) durin drag operation, default = 1
-- jumpSeg parameter documentation says:
-- jumpSeg indicates whether to generate a jumping segment or not and if to set its attributes
--	= 1 generate jumping Segment and set its visual attribute to the default jumping segment visual attribute from the visualAttrBank table
-- 	= 2 generate jumping segment but don't set any special attribute
--  = 0 then do not generate jumping segment
drawConnector  = function(cnvobj,segs,finalRouter,jsFinal,dragRouter,jsDrag)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	-- Check whether this is an interactive move or not
	local interactive
	if type(segs) ~= "table" then
		interactive = true
	end
	
	print("DRAW CONNECTOR START")
	
	local rm = cnvobj.rM
	
	if not interactive then
		-- Check segs validity
		--[[
		segments = {	-- Array of segment structures
			[i] = {
				start_x = <integer>,		-- starting coordinate x of the segment
				start_y = <integer>,		-- starting coordinate y of the segment
				end_x = <integer>,			-- ending coordinate x of the segment
				end_y = <integer>			-- ending coordinate y of the segment
			}
		},
		]]
		-- Take care of grid snapping
		local conn = cnvobj.drawn.conn	-- Data structure containing all connectors
		local junc = {}			-- To store all new created junctions
		for i = 1,#segs do
			if not segs[i].start_x or type(segs[i].start_x) ~= "number" then
				return nil,"Invalid or missing coordinate."
			end
			if not segs[i].start_y or type(segs[i].start_y) ~= "number" then
				return nil,"Invalid or missing coordinate."
			end
			if not segs[i].end_x or type(segs[i].end_x) ~= "number" then
				return nil,"Invalid or missing coordinate."
			end
			if not segs[i].end_y or type(segs[i].end_y) ~= "number" then
				return nil,"Invalid or missing coordinate."
			end
			-- Do the snapping of the coordinates first
			segs[i].start_x,segs[i].start_y = cnvobj:snap(segs[i].start_x,segs[i].start_y)
			segs[i].end_x,segs[i].end_y = cnvobj:snap(segs[i].end_x,segs[i].end_y)
			local jcst,jcen=0,0	-- counters to count how many segments does the start point of the i th segment connects to (jcst) and how many segments does the end point of the i th segment connects to (jcen)
			for j = 1,#segs do
				if j ~= i then
					-- the end points of the ith segment should not lie anywhere on the jth segment except its ends
					local ep = true	-- is the jth segment connected to one of the end points of the ith segment?
					if segs[i].start_x == segs[j].start_x and segs[i].start_y == segs[j].start_y then
						jcst = jcst + 1
					elseif segs[i].start_x == segs[j].end_x and segs[i].start_y == segs[j].end_y then
						jcst = jcst + 1
					elseif segs[i].end_x == segs[j].end_x and segs[i].end_y == segs[j].end_y then
						jcen = jcen + 1
					elseif segs[i].end_x == segs[j].start_x and segs[i].end_y == segs[j].start_y then
						jcen = jcen + 1
					else
						ep = false
					end
					if not ep and (coorc.pointOnSegment(segs[j].start_x, segs[j].start_y, segs[j].end_x, segs[j].end_y, segs[i].start_x, segs[i].start_y)  
					  or coorc.pointOnSegment(segs[j].start_x, segs[j].start_y, segs[j].end_x, segs[j].end_y, segs[i].end_x, segs[i].end_y)) then
						return nil, "The end point of a segment touches a mid point of another segment."	-- This is not allowed since that segment should have been split into 2 segments
					end
				end
			end
			if jcst > 1 then
				-- More than 1 segment connects the starting point of the ith segment so the starting point is a junction and 1 is the ith segment so that makes more than 2 segments connecting at the starting point of the ith segment
				if not tu.inArray(junc,{x=segs[i].start_x,y=segs[i].start_y},equalCoordinate) then
					junc[#junc + 1] = {x=segs[i].start_x,y=segs[i].start_y}
				end
			end
			if jcen > 1 then
				if not tu.inArray(junc,{x=segs[i].end_x,y=segs[i].end_y},equalCoordinate) then
					junc[#junc + 1] = {x=segs[i].end_x,y=segs[i].end_y}
				end
			end
		end		-- for i = 1,#segs ends here
		-- Add the segments to the routing matrix
		for i = 1,#segs do
			rm:addSegment(segs[i],segs[i].start_x,segs[i].start_y,segs[i].end_x,segs[i].end_y)
		end
		-- Create a new connector using the segments
		conn[#conn + 1] = {
			segments = segs,
			id="C"..tostring(conn.ids + 1),
			order=#cnvobj.drawn.order+1,
			junction=junc,
			port={}
		}
		conn.ids = conn.ids + 1
		-- Add the connector to the order array
		cnvobj.drawn.order[#cnvobj.drawn.order + 1] = {
			type = "connector",
			item = conn[#conn]
		}
		-- Now lets check whether there are any shorts to any other connector by this dragged segment. The shorts can be on the segment end points
		-- remove any overlaps in the final merged connector
		local mergeMap = shortAndMergeConnectors(cnvobj,{conn[#conn]})
		-- Connect overlapping ports
		connectOverlapPorts(cnvobj,mergeMap[#mergeMap][1])		-- Note shortAndMergeConnectors also runs repairSegAndJunc
		return true
	end
	-- Setup interactive drawing
	
	-- Connector drawing methodology
	-- Connector drawing starts with Event 1. This event may be a mouse event or a keyboard event
	-- Connector waypoint is set with Event 2. This event may be a mouse event or a keyboard event. The waypoint freezes the connector route up till that point
	-- Connector drawing stops with Event 3. This event may be a mouse event or a keyboard event.
	-- For now the events are defined as follows:
	-- Event 1 = Mouse left click
	-- Event 2 = Mouse left click after connector start
	-- Event 3 = Mouse right click or clicking on a port or clicking on a connector
	
	-- Backup the old button_cb and motion_cb functions
	local oldBCB = cnvobj.cnv.button_cb
	local oldMCB = cnvobj.cnv.motion_cb
	
	local op = {}
	cnvobj.op[#cnvobj.op + 1] = op
	
	local function setWaypoint(x,y)
		op.startseg = #cnvobj.drawn.conn[#cnvobj.drawn.conn].segments+1
		op.start = {x=op.fin.x,y=op.fin.y}
	end
	
	local function endConnector()
		-- Check whether the new segments overlap any port
		-- Note that ports can only happen at the start and end of the whole connector
		-- This is because routing avoids ports unless it is the ending point	
		if cnvobj.op[#cnvobj.op].mode == "DRAWCONN" then
			local conn = cnvobj.drawn.conn[op.cIndex]
			local segTable = conn.segments
			if #segTable == 0 then
				-- Remove this connector
				table.remove(cnvobj.drawn.order,conn.order)
				table.remove(cnvobj.drawn.conn,op.cIndex)
			else
				-- Add the segments to the routing matrix
				for i = 1,#segTable do
					rm:addSegment(segTable[i],segTable[i].start_x,segTable[i].start_y,segTable[i].end_x,segTable[i].end_y)
				end

				-- Now lets check whether there are any shorts to any other connector by this dragged segment. The shorts can be on the segment end points
				-- remove any overlaps in the final merged connector
				local mergeMap = shortAndMergeConnectors(cnvobj,{conn})
				-- Connect overlapping ports
				connectOverlapPorts(cnvobj,mergeMap[#mergeMap][1])		-- Note shortAndMergeConnectors also runs repairSegAndJunc
			end
		end
		cnvobj.op[#cnvobj.op] = nil
		cnvobj.cnv.button_cb = oldBCB
		cnvobj.cnv.motion_cb = oldMCB
	end		-- Function endConnector ends here
	
	local function startConnector(X,Y)
		print("START CONNECTOR")
		local conn = cnvobj.drawn.conn
		op.startseg = 1		-- segment number from where to generate the segments
		-- Check if the starting point lays on another connector
		op.connID = "C"..tostring(cnvobj.drawn.conn.ids + 1)
		op.cIndex = #cnvobj.drawn.conn + 1		-- Storing this connector in a new connector structure. Will merge it with other connectors if required in endConnector
		op.mode = "DRAWCONN"	-- Set the mode to drawing object
		op.start = {x=X,y=Y}	-- snapping is done in generateSegments
		op.fin = {x=X,y=Y}	-- To store the coordinates till where the connector is currently routed
		op.finish = endConnector
		--cnvobj.op.splitseg may also be set in the above loop
		--cnvobj.op.startseg is set
	end
	
	-- button_CB to handle connector drawing
	function cnvobj.cnv:button_cb(button,pressed,x,y,status)
		--y = cnvobj.height - y
		-- Check if any hooks need to be processed here
		cnvobj:processHooks("MOUSECLICKPRE",{button,pressed,x,y,status})
		local xo,yo = x,y
		x,y = cnvobj:snap(x,y)
		if button == iup.BUTTON1 and pressed == 1 then
			if cnvobj.op[#cnvobj.op].mode ~= "DRAWCONN" then
				print("Start connector drawing at ",x,y)
				startConnector(x,y)
			elseif #cnvobj:getPortFromXY(x, y) > 0 or #getConnFromXY(cnvobj,x,y,0) > 1 then	-- 1 is the connector being drawn right now
				endConnector()
			else
				setWaypoint(x,y)
			end
		end
		if button == iup.BUTTON3 and pressed == 1 then
			-- Event 3 (right click)
			endConnector()
		end
		-- Process any hooks 
		cnvobj:processHooks("MOUSECLICKPOST",{button,pressed,xo,yo,status})
	end
	
	dragRouter = dragRouter or cnvobj.options.router[9]
	jsDrag = jsDrag or 1
	
	function cnvobj.cnv:motion_cb(x,y,status)
		--connectors
		if cnvobj.op[#cnvobj.op].mode == "DRAWCONN" then
			--y = cnvobj.height - y
			local cIndex = op.cIndex
			local segStart = op.startseg
			local startX = op.start.x
			local startY = op.start.y
			if not cnvobj.drawn.conn[cIndex] then
				-- new connector object described below:
				cnvobj.drawn.conn[cIndex] = {
					segments = {},
					id=op.connID,
					order=#cnvobj.drawn.order+1,
					junction={},
					port={}
				}
				-- Update the connector id counter
				cnvobj.drawn.conn.ids = cnvobj.drawn.conn.ids + 1
				-- Add the connector to be drawn in the order array
				cnvobj.drawn.order[#cnvobj.drawn.order + 1] = {
					type = "connector",
					item = cnvobj.drawn.conn[op.cIndex]
				}
			end
			local connector = cnvobj.drawn.conn[cIndex]
			-- Remove all the segments that need to be regenerated
			print("Remove segments:")
			for i = #connector.segments,segStart,-1 do
				cnvobj.rM:removeSegment(connector.segments[i])
				table.remove(connector.segments,i)
			end
			print("DONE")
			print("GENERATE SEGMENTS")
			op.fin.x,op.fin.y = router.generateSegments(cnvobj, startX,startY,x, y,connector.segments,dragRouter,jsDrag)
			cnvobj:refresh()
		end			
	end
	
end	-- end drawConnector function


