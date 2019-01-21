#version 300 es

precision highp float;
precision highp int;
precision highp sampler2D;

#include <pathtracing_uniforms_and_defines>

uniform sampler2D tTriangleTexture;
uniform sampler2D tAABBTexture;
uniform sampler2D tAlbedoTextures[8]; // 8 = max number of diffuse albedo textures per model

//float InvTextureWidth = 0.000244140625; // (1 / 4096 texture width)
//float InvTextureWidth = 0.00048828125;  // (1 / 2048 texture width)
//float InvTextureWidth = 0.0009765625;   // (1 / 1024 texture width)

#define INV_TEXTURE_WIDTH 0.00048828125

#define N_SPHERES 5
#define N_BOXES 2

//-----------------------------------------------------------------------

struct Ray { vec3 origin; vec3 direction; };
struct Sphere { float radius; vec3 position; vec3 emission; vec3 color; int type; };
struct Box { vec3 minCorner; vec3 maxCorner; vec3 emission; vec3 color; int type; };
struct Intersection { vec3 normal; vec3 emission; vec3 color; vec2 uv; int type; int albedoTextureID; };

Sphere spheres[N_SPHERES];
Box boxes[N_BOXES];


#include <pathtracing_random_functions>

#include <pathtracing_calc_fresnel_reflectance>

#include <pathtracing_sphere_intersect>

#include <pathtracing_box_intersect>

#include <pathtracing_boundingbox_intersect>

#include <pathtracing_bvhTriangle_intersect>

struct StackLevelData
{
        float id;
        float rayT;
} stackLevels[24];

struct BoxNode
{
	float branch_A_Index;
	vec3 minCorner;
	float branch_B_Index;
	vec3 maxCorner;
};

BoxNode GetBoxNode(const in float i)
{
	// each bounding box's data is encoded in 2 rgba(or xyzw) texture slots
	float iX2 = (i * 2.0);
	// (iX2 + 0.0) corresponds to .x: idLeftChild, .y: aabbMin.x, .z: aabbMin.y, .w: aabbMin.z
	// (iX2 + 1.0) corresponds to .x: idRightChild .y: aabbMax.x, .z: aabbMax.y, .w: aabbMax.z

	vec2 uv0 = vec2( (mod(iX2 + 0.0, 2048.0)), floor((iX2 + 0.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
	vec2 uv1 = vec2( (mod(iX2 + 1.0, 2048.0)), floor((iX2 + 1.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;

	vec4 aabbNodeData0 = texture( tAABBTexture, uv0 );
	vec4 aabbNodeData1 = texture( tAABBTexture, uv1 );

	BoxNode BN = BoxNode( aabbNodeData0.x,
			      aabbNodeData0.yzw,
			      aabbNodeData1.x,
			      aabbNodeData1.yzw );

        return BN;
}

//----------------------------------------------------------
float SceneIntersect( Ray r, inout Intersection intersec )
//----------------------------------------------------------
{
	vec3 n;
	float d = INFINITY;
	float t = INFINITY;

	// AABB BVH Intersection variables
	vec4 aabbNodeData0, aabbNodeData1, aabbNodeData2;
	vec4 vd0, vd1, vd2, vd3, vd4, vd5, vd6, vd7;
	vec3 aabbMin, aabbMax;
	vec3 inverseDir = 1.0 / r.direction;
	vec3 hitPos, toLightBulb;
	vec2 uv0, uv1, uv2, uv3, uv4, uv5, uv6, uv7;

        float stackptr = 0.0;
	float bc, bd;
	float id = 0.0;
	float tu, tv;
	float triangleID = 0.0;
	float triangleU = 0.0;
	float triangleV = 0.0;
	float triangleW = 0.0;

	bool skip = false;
	bool triangleLookupNeeded = false;

	BoxNode currentBoxNode, nodeA, nodeB, tnp;
	StackLevelData currentStackData, slDataA, slDataB, tmp;

	for (int i = 0; i < N_SPHERES; i++)
        {
		d = SphereIntersect( spheres[i].radius, spheres[i].position, r );
		if (d < t)
		{
			t = d;
			intersec.normal = (r.origin + r.direction * t) - spheres[i].position;
			intersec.emission = spheres[i].emission;
			intersec.color = spheres[i].color;
			intersec.type = spheres[i].type;
			intersec.albedoTextureID = -1;
			triangleLookupNeeded = false;
		}
	}

	currentBoxNode = GetBoxNode(stackptr);
	currentStackData = StackLevelData(stackptr, BoundingBoxIntersect(currentBoxNode.minCorner, currentBoxNode.maxCorner, r.origin, inverseDir));
	stackLevels[0] = currentStackData;

	while (true)
        {

		if (currentStackData.rayT < t + 65.0) // 65.0 is the magic number for this scene
                {

                        if (currentBoxNode.branch_A_Index >= 0.0) // signifies this is a branch
                        {
                                nodeA = GetBoxNode(currentBoxNode.branch_A_Index);
                                nodeB = GetBoxNode(currentBoxNode.branch_B_Index);
                                slDataA = StackLevelData(currentBoxNode.branch_A_Index, BoundingBoxIntersect(nodeA.minCorner, nodeA.maxCorner, r.origin, inverseDir));
                                slDataB = StackLevelData(currentBoxNode.branch_B_Index, BoundingBoxIntersect(nodeB.minCorner, nodeB.maxCorner, r.origin, inverseDir));

				// first sort the branch node data so that 'a' is the smallest
				if (slDataB.rayT < slDataA.rayT)
				{
					tmp = slDataB;
					slDataB = slDataA;
					slDataA = tmp;

					tnp = nodeB;
					nodeB = nodeA;
					nodeA = tnp;
				} // branch 'b' now has the larger rayT value of 'a' and 'b'

				if (slDataB.rayT < INFINITY) // see if branch 'b' (the larger rayT) needs to be processed
				{
					currentStackData = slDataB;
					currentBoxNode = nodeB;
					skip = true; // this will prevent the stackptr from decreasing by 1
				}
				if (slDataA.rayT < INFINITY) // see if branch 'a' (the smaller rayT) needs to be processed
				{
					if (skip == true) // if larger branch 'b' needed to be processed also,
						stackLevels[int(stackptr++)] = slDataB; // cue larger branch 'b' for future round
								// also, increase pointer by 1

					currentStackData = slDataA;
					currentBoxNode = nodeA;
					skip = true; // this will prevent the stackptr from decreasing by 1
				}
                        }

                        else //if (currentBoxNode.branch_A_Index < 0.0) //  < 0.0 signifies a leaf node
                        {
				// each triangle's data is encoded in 8 rgba(or xyzw) texture slots
				id = 8.0 * (-currentBoxNode.branch_A_Index - 1.0);
				uv0 = vec2( (mod(id + 0.0, 2048.0)), floor((id + 0.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
				uv1 = vec2( (mod(id + 1.0, 2048.0)), floor((id + 1.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
				uv2 = vec2( (mod(id + 2.0, 2048.0)), floor((id + 2.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;

				vd0 = texture( tTriangleTexture, uv0 );
				vd1 = texture( tTriangleTexture, uv1 );
				vd2 = texture( tTriangleTexture, uv2 );

				d = BVH_TriangleIntersect( vec3(vd0.xyz), vec3(vd0.w, vd1.xy), vec3(vd1.zw, vd2.x), r, tu, tv );

				if (d < t && d > 0.0)
				{
					t = d;
					triangleID = id;
					triangleU = tu;
					triangleV = tv;
					triangleLookupNeeded = true;
				}
                        }
		} // end if (currentStackData.rayT < t)

		if (skip == false)
                {
                        // decrease pointer by 1 (0.0 is root level, 24.0 is maximum depth)
                        if (--stackptr < 0.0) // went past the root level, terminate loop
                                break;
                        currentStackData = stackLevels[int(stackptr)];
                        currentBoxNode = GetBoxNode(currentStackData.id);
                }
		skip = false; // reset skip

        } // end while (true)


	if (triangleLookupNeeded)
	{
		uv0 = vec2( (mod(triangleID + 0.0, 2048.0)), floor((triangleID + 0.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
		uv1 = vec2( (mod(triangleID + 1.0, 2048.0)), floor((triangleID + 1.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
		uv2 = vec2( (mod(triangleID + 2.0, 2048.0)), floor((triangleID + 2.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
		uv3 = vec2( (mod(triangleID + 3.0, 2048.0)), floor((triangleID + 3.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
		uv4 = vec2( (mod(triangleID + 4.0, 2048.0)), floor((triangleID + 4.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
		uv5 = vec2( (mod(triangleID + 5.0, 2048.0)), floor((triangleID + 5.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
		uv6 = vec2( (mod(triangleID + 6.0, 2048.0)), floor((triangleID + 6.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;
		uv7 = vec2( (mod(triangleID + 7.0, 2048.0)), floor((triangleID + 7.0) * INV_TEXTURE_WIDTH) ) * INV_TEXTURE_WIDTH;

		vd0 = texture( tTriangleTexture, uv0 );
		vd1 = texture( tTriangleTexture, uv1 );
		vd2 = texture( tTriangleTexture, uv2 );
		vd3 = texture( tTriangleTexture, uv3 );
		vd4 = texture( tTriangleTexture, uv4 );
		vd5 = texture( tTriangleTexture, uv5 );
		vd6 = texture( tTriangleTexture, uv6 );
		vd7 = texture( tTriangleTexture, uv7 );

		// face normal for flat-shaded polygon look
		//intersec.normal = normalize( cross(vec3(vd0.w, vd1.xy) - vec3(vd0.xyz), vec3(vd1.zw, vd2.x) - vec3(vd0.xyz)) );

		// interpolated normal using triangle intersection's uv's
		triangleW = 1.0 - triangleU - triangleV;
		intersec.normal = normalize(triangleW * vec3(vd2.yzw) + triangleU * vec3(vd3.xyz) + triangleV * vec3(vd3.w, vd4.xy));
		intersec.emission = vec3(1, 0, 1); // use this if intersec.type will be LIGHT
		intersec.color = vd6.yzw;
		intersec.uv = triangleW * vec2(vd4.zw) + triangleU * vec2(vd5.xy) + triangleV * vec2(vd5.zw);
		intersec.type = int(vd6.x);
		intersec.albedoTextureID = int(vd7.x);
	}

	return t;

} // end float SceneIntersect( Ray r, inout Intersection intersec )



//-----------------------------------------------------------------------
vec3 CalculateRadiance( Ray r, inout uvec2 seed )
//-----------------------------------------------------------------------
{
	Intersection intersec;
	vec3 accumCol = vec3(0.0);
        vec3 mask = vec3(1.0);
	vec3 checkCol0 = vec3(1);
	vec3 checkCol1 = vec3(0.5);
        vec3 tdir;

	float nc, nt, Re;
        float epsIntersect = 0.01;

	bool bounceIsSpecular = true;


        for (int depth = 0; depth < 4; depth++)
	{

		float t = SceneIntersect(r, intersec);

		if (t == INFINITY)
		{
                        break;
		}

		// if we reached something bright, don't spawn any more rays
		if (intersec.type == LIGHT)
		{
			//if (bounceIsSpecular)
			{
				accumCol = mask * intersec.emission;
			}

			break;
		}


		// useful data
		vec3 n = intersec.normal;
                vec3 nl = dot(n,r.direction) <= 0.0 ? normalize(n) : normalize(n * -1.0);
		vec3 x = r.origin + r.direction * t;


                if (intersec.type == DIFF || intersec.type == CHECK) // Ideal DIFFUSE reflection
                {
			if( intersec.type == CHECK )
			{
				float q = clamp( mod( dot( floor(x.xz * 0.04), vec2(1.0) ), 2.0 ) , 0.0, 1.0 );
				intersec.color = checkCol0 * q + checkCol1 * (1.0 - q);
			}

			mask *= intersec.color;
			bounceIsSpecular = false;

			// Russian Roulette
			float p = max(mask.r, max(mask.g, mask.b));
			if (depth > 0)
			{
				if (rand(seed) < p)
                                	mask *= 1.0 / p;
                        	else
                                	break;
			}

			// choose random Diffuse sample vector
			r = Ray( x, randomCosWeightedDirectionInHemisphere(nl, seed) );
			r.origin += r.direction * epsIntersect;
			continue;
                }

                if (intersec.type == SPEC)  // Ideal SPECULAR reflection
                {
			r = Ray( x, reflect(r.direction, nl) );
			r.origin += r.direction * epsIntersect;
			mask *= intersec.color;
			bounceIsSpecular = true;
                        continue;
                }

                if (intersec.type == REFR)  // Ideal dielectric REFRACTION
		{
			nc = 1.0; // IOR of Air
			nt = 1.5; // IOR of common Glass
			Re = calcFresnelReflectance(n, nl, r.direction, nc, nt, tdir);

			//if (diffuseCount < 2)
				bounceIsSpecular = true;

			if (rand(seed) < Re) // reflect ray from surface
			{
				r = Ray( x, reflect(r.direction, nl) );
				r.origin += r.direction * epsIntersect;
			    	continue;
			}
			else // transmit ray through surface
			{
				mask *= intersec.color;
				r = Ray(x, tdir);
				r.origin += r.direction * epsIntersect;
				continue;
			}

		} // end if (intersec.type == REFR)

		if (intersec.type == COAT)  // Diffuse object underneath with ClearCoat on top (like car, or shiny pool ball)
		{
			nc = 1.0; // IOR of Air
			nt = 1.4; // IOR of ClearCoat
			Re = calcFresnelReflectance(n, nl, r.direction, nc, nt, tdir);

			// choose either specular reflection or diffuse
			if( rand(seed) < Re )
			{
				r = Ray( x, reflect(r.direction, nl) );
				r.origin += r.direction * epsIntersect;
				bounceIsSpecular = true;
				continue;
			}
			else
			{
				mask *= intersec.color;

				int id = intersec.albedoTextureID;
				if (id > -1)
				{
					vec3 albedoSample;
					     if (id == 0) albedoSample = texture(tAlbedoTextures[0], intersec.uv).rgb;
					else if (id == 1) albedoSample = texture(tAlbedoTextures[1], intersec.uv).rgb;
					else if (id == 2) albedoSample = texture(tAlbedoTextures[2], intersec.uv).rgb;
					else if (id == 3) albedoSample = texture(tAlbedoTextures[3], intersec.uv).rgb;
					else if (id == 4) albedoSample = texture(tAlbedoTextures[4], intersec.uv).rgb;
					else if (id == 5) albedoSample = texture(tAlbedoTextures[5], intersec.uv).rgb;
					else if (id == 6) albedoSample = texture(tAlbedoTextures[6], intersec.uv).rgb;
					else if (id == 7) albedoSample = texture(tAlbedoTextures[7], intersec.uv).rgb;

					mask *= albedoSample;
				}

				r = Ray( x, randomCosWeightedDirectionInHemisphere(nl, seed) );
				r.origin += r.direction * epsIntersect;
				bounceIsSpecular = false;
				continue;
			}

		} //end if (intersec.type == COAT)


	} // end for (int depth = 0; depth < 5; depth++)

	return accumCol;
}


//-----------------------------------------------------------------------
void SetupScene(void)
//-----------------------------------------------------------------------
{
	vec3 z  = vec3(0);
	vec3 L3 = vec3(1, 0.984, 0.941);// yellowish light

	spheres[0] = Sphere( 10000.0,     vec3(0, 0, 0), L3,                 z, LIGHT);//spherical white Light1
	spheres[1] = Sphere(  4000.0, vec3(0, -4000, 0),  z, vec3(0.4,0.4,0.4), CHECK);//Checkered Floor
}


#include <pathtracing_main>