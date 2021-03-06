-- Test case 3 with 1 floating connector and 1 object with a port
o1 = cnvobj:drawObj("RECT",{{x=200,y=300},{x=300,y=450}})

-- Now add a port to each object
p1 = cnvobj:addPort(300,380,o1.id)

-- Add the port visual rectangles
cnvobj.grid.snapGrid = false
o3 = cnvobj:drawObj("FILLEDRECT",{{x=300-3,y=380-3},{x=300+3,y=380+3}})
cnvobj.grid.snapGrid = true
-- Group the port visuals with the objects
cnvobj:groupObjects({o1,o3})

-- Now draw the connector
-- One connector is just 2 segment direct ther other one is 4 segments but give it as 1 and it should split it into 2 across ports
cnvobj:drawConnector({
		{start_x = 400,start_y=130,end_x=500,end_y=130},
		{start_x = 500,start_y=130,end_x=500,end_y=220},
		{start_x = 500,start_y=220,end_x=600,end_y=220},
	})
cnvobj:refresh()
