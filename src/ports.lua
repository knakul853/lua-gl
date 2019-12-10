-- Module to handle the ports structure
local type = type
local math = math
local tostring = tostring
local table = table

local coorc = require("lua-gl.CoordinateCalc")

local M = {}
package.loaded[...] = M
if setfenv and type(setfenv) == "function" then
	setfenv(1,M)	-- Lua 5.1
else
	_ENV = M		-- Lua 5.2+
end

-- The port structure looks like this:
--[[
{
	id = <integer>,		-- Unique identification number for the port. Format is P<num> i.e. P followed by a unique number
	conn = <array>,		-- Array of connectors connected to the port
	obj = <Object>,		-- Pointer to the object structure to which the port is associated with
	x = x,
	y = y
}
]]
-- The port structure is located at cnvobj.drawn.port

getPortFromXY = function(cnvobj, x, y)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	local ports = cnvobj.drawn.port
	if #ports == 0 then
		return {}
	end
	local res = math.floor(math.min(cnvobj.grid_x,cnvobj.grid_y)/2)
	local allPorts = {}
	for i = 1, #ports do
		if math.abs(ports[i].x - x) <= res and math.abs(cnvobj.port[i].y - y) <= res then
				allPorts[#allPorts + 1] = ports[i]
		end
	end
	return allPorts
end

getPortFromID = function(cnvobj,portID)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	local ports = cnvobj.drawn.port
	for i = 1,#ports do
		if ports[i].id == portID then
			return ports[i]
		end
	end
	return nil,"No matching port found"
end

-- Add a port to an object
-- A port is defined as a stick point for a connector. Any connector that passes over a point occupied by a port will get connected to it.
-- Subsequent movement of the port or connector will try to maintain the port connections
-- Note ports can only be added to object and a port can only be associated with 1 object
addPort = function(cnvobj,x,y,objID)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	if not objID or type(objID) ~= "number" or not cnvobj:getObjectFromID(objID) then
		return nil,"Need valid shapeID"
	end
	local obj = cnvobj:getObjFromID(objID)
	if not obj then
		return nil,"Object not found"
	end
	local grdx,grdy = cnvobj.grid_x,cnvobj.grid_y
	if not cnvobj.snapGrid then
		grdx,grdy = 1,1
	end
	x = coorc.snapX(x, grdx)
	y = coorc.snapY(y, grdy)
	local index = #cnvobj.port + 1
	local portID = "P"..tostring(cnvobj.drawn.port.ids + 1)
	cnvobj.drawn.port.ids = cnvobj.drawn.port.ids + 1
	
	cnvobj.drawn.port[index] = {
		id = portID,
		conn = {},
		obj = obj,
		x = x,
		y = y
	}
	
	-- Link the port table to the object
	obj.port[#obj.port + 1] = cnvobj.drawn.port[index]		
	return true
end

removePort = function(cnvobj,portID)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	local ports = cnvobj.drawn.port
	for i = 1,#ports do
		if ports[i].id == portID then
			-- Remove the port from the object
			local objports = ports[i].obj.port
			for j = 1,#objports do
				if objports[j] == ports[i] then
					table.remove(objports,j)
					break
				end
			end
			table.remove(ports,i)
			break
		end
	end
	return true
end

-- Function to check if any ports in the drawn data port array (or, if given, in the ports array) touch any other ports. All touching ports are connected with a connector if not already connected
-- A connector between overlapping ports will be a connector with no segments
connectOverlapPorts = function(cnvobj,ports)
	if not cnvobj or type(cnvobj) ~= "table" then
		return nil,"Not a valid lua-gl object"
	end
	ports = ports or cnvobj.drawn.port
	local allPorts = cnvobj.drawn.port
	
	for i = 1,#ports  do		-- Check for every port in the list
		for j = 1,#allPorts do
			if allPorts[j] ~= ports[i] then
				if ports[i].x == allPorts[j].x and ports[i].y == allPorts[j].y then
					-- These ports overlap
					-- Check if they connect through a connector
					local conns = ports[i].conn
					local found
					for k = 1,#conns do
						-- Check if this connector also connected to allPorts[j]
						local connPorts = conns[k].port
						for l = 1,#connPorts do
							if connPorts[l] == allPorts[j] then
								found = true
								break
							end
						end
						if found then break end
					end
					if not found then
						-- Connect the ports through a connector
						local conn = cnvobj.drawn.conn
						-- Create a new connector using the segments
						conn[#conn + 1] = {
							segments = {},		-- No segments
							id="C"..tostring(conn.ids + 1),
							order=#cnvobj.drawn.order+1,
							junction={},
							port={
								ports[i],
								allPorts[j]
							}
						}
						conn.ids = conn.ids + 1
						-- Add the connector to the order array
						cnvobj.drawn.order[#cnvobj.drawn.order + 1] = {
							type = "connector",
							item = conn[#conn]
						}
						-- Add the connector to the ports
						conns[#conns + 1] = conn[#conn]
						allPorts[j].conn[#allPorts[j].conn + 1] = conn[#conn]
					end		-- if not found then ends
				end		-- if ports[i].x == allPorts[j].x and ports[i].y == allPorts[j].y then ends
			end		-- if allPorts[j] ~= ports[i] then ends
		end		-- for j = 1,#allPorts do ends
	end		-- for i = 1,#ports  do ends
end