function [P_t_full,P_t_ml,P_t_full_comp,P_t_ml_comp] = Facet_Echo_Model(op_mode,lambda,bandwidth,P_T,h,v,pitch,roll,prf,beam_weighting,G_0,D_0,gamma1,gamma2,N_b,t,PosT_s,PosT_si,surface_type,sigma_0_snow_surf,sigma_0_snow_vol,kappa_e,tau_snow,c_s,h_s,sigma_0_ice_surf,sigma_0_lead_surf,sigma_0_mp_surf)

%% Facet-based Radar Altimeter Echo Model for Sea Ice

% Simulates the backscattered echo response of a pulse-limited or synthetic
% aperture radar altimeter from snow-covered sea ice, over a facet-based
% triangular mesh of the sea ice surface topography

%% Input (reference values)
% op_mode = operational mode: 1 = pulse-limited, 2 = SAR (PL-mode only feasible on high memory machines)
% lambda = radar wavelength, 0.0221 m
% bandwidth = antenna bandwidth, Hz
% P_T = transmitted peak power, 2.188e-5 watts
% h = satellite altitude, 720000 m
% v = satellite velocity, 7500 m/s
% pitch = antenna bench pitch counterclockwise, rads (up to ~0.005 rads)
% roll = antenna bench roll counterclockwise, rads (up to ~0.005 rads)
% prf = pulse-repitition frequency, Hz
% beam_weighting = weighting function on beam pattern (1 = rectangular, 2 =
% Hamming)
% G_0 = peak antenna gain, dB
% gamma1 = along-track antenna parameter, 0.0116 rads
% gamma2 = across-track antenna parameter, 0.0129 rads
% N_b = no. beams in synthetic aperture, 64 (1 in PL mode)
% t = time, s
% PosT_si = surface facet xyz locations (n x 3 matrix)
% surface_type = surface facet type: 0 = lead/ocean, 1 = sea ice, 2 = melt
% pond (n x 3 matrix)
% theta = angular sampling of scattering signatures, rads
% sigma_0_snow_surf = backscattering coefficient of snow surface, dB
% sigma_0_snow_vol = backscattering coefficient of snow volume, dB 
% kappa_e = extinction coefficient of snow volume, Np/m
% tau_snow = transmission coefficient at air-snow interface
% c_s = speed of light in snowpack, m/s
% h_s = snow depth, m
% sigma_0_ice_surf = backscattering coefficient of ice surface, dB
% sigma_0_lead_surf = backscattering coefficient of lead surface, dB
% sigma_0_mp_surf = backscattering coefficient of pond surface, dB

%% Output
% P_t_full = delay-Doppler map (DDM) of single look echoes, watts
% P_t_ml = multi-looked power waveform, watts
% P_t_full_comp = DDM for individual snow surface, snow volume, ice
% surface, and lead surface components, watts
% P_t_ml_comp = multi-looked power waveforms for individual snow surface,
% snow volume, ice surface, and lead surface components, watts

% Based on model equations introduced in Landy et al, TGARS, 2019
% Builing on theory of Wingham et al 2006, Giles et al 2007,
% Makynen et al 2009, Ulaby et al 2014

% Uses the following codes from external sources:
% computeNormalVectorTriangulation.m (David Gingras)

% (c) Jack Landy, University of Bristol, 2018


%% Antenna parameters

c = 299792458; % speed of light, m/s
Re = 6371*10^3; % earth's radius, m

f_c = c/lambda; % radar frequency, Hz
k0 = (2*pi)/lambda; % wavenumber

delta_x = v/prf; % distance between coherent pulses in synthetic aperture, m

delta_x_dopp = (h*prf*c)/(2*N_b*v*f_c); % along-track doppler-beam limited footprint size, m
delta_x_pl = 2*sqrt(c*(h/((Re+h)/Re))*(1/bandwidth)); % across-track pulse-limited footprint size, m
delta_x_bl = 2*h*tan(gamma2/2);
A_pl = pi*(delta_x_pl/2)^2; % area of each range ring (after waveform peak), m

epsilon_b = lambda/(2*N_b*v*(1/prf)); % angular resolution of beams from full look crescent (beam separation angle) 

% Antenna look geometry
m = -(N_b-1)/2:(N_b-1)/2;

%% Triangulate surface

% Triangulate
TRI_s = delaunay(PosT_s(:,1),PosT_s(:,2));
TRI_si = delaunay(PosT_si(:,1),PosT_si(:,2));

SURFACE_TYPE = surface_type(TRI_si(:,1));

% Simplify triangulation to improve speed
% simplication_factor = 0.8; % Fraction of facets remaining after simplification
% figure;DT=trisurf(TRI,PosTx,PosTy,PosTz); set(gcf,'Visible', 'off');
% nfv=reducepatch(DT,simplification_factor);
% TRI = nfv.faces;
% PosT_si = nfv.vertices;
% PosTx = PosT_si(:,1); PosTy = PosT_si(:,2); PosTz = PosT_si(:,3);

% Compute normal vectors of facets
[NormalVx_s, NormalVy_s, NormalVz_s, PosVx_s, PosVy_s, PosVz_s]=computeNormalVectorTriangulation(PosT_s,TRI_s,'center-cells');
[NormalVx_si, NormalVy_si, NormalVz_si, PosVx_si, PosVy_si, PosVz_si]=computeNormalVectorTriangulation(PosT_si,TRI_si,'center-cells');

% Compute areas of facets sea ice
P0 = PosT_si(TRI_si(:,1),:);
P1 = PosT_si(TRI_si(:,2),:);
P2 = PosT_si(TRI_si(:,3),:);

P10 = bsxfun(@minus, P1, P0);
P20 = bsxfun(@minus, P2, P0);
V = cross(P10, P20, 2);

A_facets_si = sqrt(sum(V.*V, 2))/2;

clear P0 P1 P2 P10 P20 V

% Construct beam weighting function for azimuth FFT
if op_mode==1 || beam_weighting == 1
    H = ones(1,N_b);
elseif op_mode==2 && beam_weighting == 2    
    H = hamming(N_b);
end

%% Radar Simulator Loop
% Formulated for parallel processing

P_t_full = zeros(length(m),length(t));
sigma_0_tracer = zeros(length(m),length(t),4);
parfor i = 1:length(m)
    % disp(i);
    
    %% Angular geometry of surface snow
    
    % Antenna location
    x_0_s = h*m(i)*epsilon_b + h*tan(pitch);
    y_0_s = h*tan(roll);
    
    % Calculate basic angles
    THETA_s = pi/2 + atan2((PosVz_s-h), sqrt((PosVx_s-x_0_s).^2 + (PosVy_s-y_0_s).^2));
    PHI_s = atan2((PosVy_s-y_0_s),(PosVx_s-x_0_s));
    
    % Compute angle between facet-normal vector and antenna-facet vector
    NormalAx = cos(PHI_s).*cos(pi/2 - THETA_s);
    NormalAy = sin(PHI_s).*cos(pi/2 - THETA_s);
    NormalAz = -sin(pi/2 - THETA_s);
    theta_pr_s = pi - acos((NormalVx_s.*NormalAx + NormalVy_s.*NormalAy + NormalVz_s.*NormalAz)./(sqrt(NormalVx_s.^2 + NormalVy_s.^2 + NormalVz_s.^2).*sqrt(NormalAx.^2 + NormalAy.^2 + NormalAz.^2)));
    theta_pr_s(theta_pr_s > pi/2) = pi/2;
    
    %% Angular geometry of surface sea ice
    
    % Antenna location
    x_0_si = h*m(i)*epsilon_b + h*tan(pitch);
    y_0_si = h*tan(roll);
    
    % Calculate basic angles
    R_si = sqrt((PosVz_si-h).^2 + ((PosVx_si-x_0_si).^2 + (PosVy_si-y_0_si).^2).*(1 + h/Re));
    THETA_si = pi/2 + atan2((PosVz_si-h), sqrt((PosVx_si-x_0_si).^2 + (PosVy_si-y_0_si).^2));
    PHI_si = atan2((PosVy_si-y_0_si),(PosVx_si-x_0_si));
    
    THETA_G_si = pi/2 + atan2((PosVz_si-R_si), sqrt((PosVx_si-x_0_si+h*tan(pitch)).^2 + (PosVy_si-y_0_si+h*tan(roll)).^2));
    PHI_G_si = atan2((PosVy_si-y_0_si+h*tan(roll)),(PosVx_si-x_0_si+h*tan(pitch)));
    
    theta_l_si = atan(-(PosVx_si-x_0_si+h*tan(pitch))./(PosVz_si-h)); % look angle of radar (synthetic beam pattern unaffected by mis-pointing, following beam steering)    
    
    % Compute angle between facet-normal vector and antenna-facet vector
    NormalAx = cos(PHI_si).*cos(pi/2 - THETA_si);
    NormalAy = sin(PHI_si).*cos(pi/2 - THETA_si);
    NormalAz = -sin(pi/2 - THETA_si);
    theta_pr_si = pi - acos((NormalVx_si.*NormalAx + NormalVy_si.*NormalAy + NormalVz_si.*NormalAz)./(sqrt(NormalVx_si.^2 + NormalVy_si.^2 + NormalVz_si.^2).*sqrt(NormalAx.^2 + NormalAy.^2 + NormalAz.^2)));
    theta_pr_si(theta_pr_si > pi/2) = pi/2;
    
    %% Compute gain functions
    
    % Antenna gain pattern (based on Cryosat-2)
    G = G_0*exp(-THETA_G_si.^2.*(cos(PHI_G_si).^2/gamma1^2 + sin(PHI_G_si).^2/gamma2^2));
    
    % Synthetic beam gain function
    P_m = D_0*sin(N_b*(k0*delta_x*sin(theta_l_si+m(i)*epsilon_b))).^2./(N_b*sin(k0*delta_x*sin(theta_l_si+m(i)*epsilon_b))).^2; 
    
    %% Compute transmitted power envelope
    
    % Time offset
    tc = 2*(sqrt(x_0_si.^2*(1 + h/Re)+h^2)-h)/c; % slant-range time correction
    T = bsxfun(@minus, t + 2*h/c + tc, 2*R_si/c);
    
    % Power envelope
    P_t = (sin(bandwidth*pi*T)./(bandwidth*pi*T)).^2;
    
    %% Compute linearized backscattering
    % Surface plus volume echo (following Arthern et al 2001, Kurtz et al 2014 procedure)
    
    theta_PR = bsxfun(@times, ones(size(P_t)), theta_pr_si);
    
    % Snow volume echo from IEM and Mie extinction
    vu_t_surf = 10.^(ppval(sigma_0_snow_surf,theta_pr_s)/10)*(h_s~=0);
    vu_t_vol = 10.^(ppval(sigma_0_snow_vol,theta_PR(T>=-(2*h_s)/c_s & T<0))/10)*kappa_e.*exp(-c_s*kappa_e*(T(T>=-(2*h_s)/c_s & T<0) + (2*h_s)/c_s));
    
    vu_t_surf_tracer = bsxfun(@times,interp1(t - 2*h_s/c_s,P_t',t,'linear')',vu_t_surf); % correct echo for snow depth
    
    vu_t_vol_tracer = zeros(size(P_t)); vu_t_vol_tracer(T>=-(2*h_s)/c_s & T<0) = vu_t_vol;
    vu_t_vol_tracer = interp1(t - 2*h_s/c_s,P_t',t,'linear')'.*vu_t_vol_tracer;
    
    % Ice surface from simple approx functions
%     phi_pr = 1*(pi/180); % polar response angle for Giles et al., 2007 simplified surface scattering function
%     mu_t = zeros(size(theta_pr));
%     mu_t(SURFACE_TYPE==1) = exp(-(theta_pr(SURFACE_TYPE==1)/phi_pr).^2); % Giles et al 2007 function
%     alpha = (l_si/(2*k*sigma_si^2))^2;
%     mu_t(SURFACE_TYPE==1) = -(rho_i_0*alpha)/2*(1 + alpha*sin(theta_pr(SURFACE_TYPE==1)).^2).^(-3/2); % Kurtz et al 2014 function
    
    % Ice surface echo from IEM
    mu_t = zeros(size(theta_pr_si));
    mu_t(SURFACE_TYPE==1) = 10.^(ppval(sigma_0_ice_surf,theta_pr_si(SURFACE_TYPE==1))/10).*ppval(tau_snow,theta_pr_si(SURFACE_TYPE==1)).^2*exp(-kappa_e*h_s/2);
    
    mu_t_si_tracer = bsxfun(@times,P_t,mu_t);
    
    % Coherent reflection from water (leads or melt ponds) where necessary
    mu_t(SURFACE_TYPE==0) = 10.^(ppval(sigma_0_lead_surf,theta_pr_si(SURFACE_TYPE==0))/10);
    mu_t(SURFACE_TYPE==2) = 10.^(ppval(sigma_0_mp_surf,theta_pr_si(SURFACE_TYPE==2))/10);
    mu_t(isnan(mu_t)) = 0; % zero backscattered power at higher incidence over smooth water (change NaNs to zeros)
        
    mu_t_ocean_tracer = bsxfun(@times,P_t,mu_t) - mu_t_si_tracer;
    
    % Total echo (pre-convolved with transmitted pulse)
    sigma_0_P_t = vu_t_surf_tracer + vu_t_vol_tracer + mu_t_si_tracer + mu_t_ocean_tracer;
    
    % Backscatter component fraction tracer
    sigma_0_tracer(i,:,:) = [sum(vu_t_surf_tracer,1)./sum(sigma_0_P_t,1);sum(vu_t_vol_tracer,1)./sum(sigma_0_P_t,1);sum(mu_t_si_tracer,1)./sum(sigma_0_P_t,1);sum(mu_t_ocean_tracer,1)./sum(sigma_0_P_t,1)]';
    
    vu_t_surf_tracer = []; vu_t_vol_tracer = []; mu_t = []; mu_t_si_tracer = []; mu_t_ocean_tracer = [];
    
    %% Integrate power contributions from each facet
    
    % Integrate radar equation
    P_r = ((lambda^2*P_T)/(4*pi)^3)*(0.5*c*h)*bsxfun(@times, bsxfun(@rdivide, sigma_0_P_t, R_si.^4), G.^2.*P_m.*A_facets_si);
    
    echo_t = nansum(P_r,1);
    
    % Keeps memory use low during loop
    T = []; P_t = []; P_r = []; theta_PR = []; sigma_0_P_t = [];
    
    % Apply weighting to single-look echo stack
    P_t_full(i,:) = real(echo_t)*H(i);
        
end

% Multi-looked echo
P_t_ml = nansum(P_t_full,1)';

% Component echoes
P_t_full_comp = bsxfun(@times, sigma_0_tracer, P_t_full);
P_t_full = P_t_full';
P_t_full_comp = permute(P_t_full_comp,[2 1 3]);

P_t_ml_comp = permute(nansum(P_t_full_comp,2),[1 3 2]);


end

