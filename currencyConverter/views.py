from django.shortcuts import render, redirect
from django.contrib.auth.mixins import LoginRequiredMixin
from django.contrib.auth.decorators import login_required
from django.contrib.auth import login, logout, authenticate 
from django.views import View
from .models import *
from .forms import *
from django.contrib import messages
from django.core.mail import send_mail
from django.db.models import Q
from django.views.generic import ListView
from django.core.paginator import Paginator

amount_ = 0

def splitData(data_string):
	if '/' in data_string:
		data_list = data_string.split('/')
		return float(float(data_list[0])/float(data_list[1]))
	else:
		return float(data_string)

def index(request):
	global amount_
	template_name='index.html'
	form = ConversionForm(request.POST)
	sender = Country.objects.get(name="Canada")
	reciever = Country.objects.get(name="Burundi")
	rc_value = reciever.usd_value.split('/')[1]
	if "action" in request.POST:
		if form.is_valid():
			print(form.cleaned_data)
			request.session['first_form'] = form.cleaned_data
			amount_ = form.cleaned_data['amount']
			return redirect(step1)
	if "send" in request.POST:
		amount = float(request.POST.get('inputsend'))
		data = {'country_from': sender.usd_value, 'country_to': reciever.usd_value, 'amount': amount}
		request.session['first_form'] = data
		amount_ = float(request.POST.get('inputsend'))
		return redirect(step1)

	if "recieve" in request.POST:
		amount = float(request.POST.get('inputrecieve'))
		data = {'country_from': reciever.usd_value, 'country_to': sender.usd_value, 'amount': amount}
		request.session['first_form'] = data
		amount_ = float(request.POST.get('inputrecieve'))
		return redirect(step1)

	return render(request, template_name, locals())

@login_required(login_url=('login'))
def requests(request):
	trackings = Tracking.objects.all().order_by('-id')
	paginator = Paginator(trackings, 20)
	try:
		page_number = request.GET.get('page')
	except:
		page_number = 1
	page_obj = paginator.get_page(page_number)

	return render(request, 'requests.html', {'page_obj': page_obj})

@login_required(login_url=('login'))
def validerRecu(request, id):
	track = Tracking.objects.get(id=id)
	valid_form = ValidationForm(request.POST or None, initial={'amount':track.amount_in})
	if valid_form.is_valid():
		valid = valid_form.cleaned_data
		track.amount_in_recieve = valid['amount']
		track.amount_out_deliver = float(valid['amount'])*(splitData(track.currency_in.usd_value)/splitData(track.currency_out.usd_value))
		track.motif_validate1 = valid['motif_validate1']
		track.validated1 = True
		track.save()
		return redirect(requests)
	return render(request, 'valider_modal.html', locals())

@login_required(login_url=('login'))
def validerEnvoie(request, id):
	track = Tracking.objects.get(id=id)
	track.validated2 = True
	track.save()
	return redirect(requests)

def step1(request):
	global amount_
	default_data = {'amount': amount_}

	step_form1 = StepForm1(request.POST or None,initial=default_data)
	if step_form1.is_valid():
		request.session['step_form1'] = step_form1.cleaned_data
		return redirect(step2)
	return render(request, 'steps_forms.html', locals())

def step2(request):
	step_form2 = StepForm2(request.POST or None)
	if step_form2.is_valid():
		request.session['step_form2'] = step_form2.cleaned_data
		first_ = request.session.pop('first_form',{})
		step_1 = request.session.pop('step_form1',{})
		step_2 = request.session.pop('step_form2',{})
		c_in = Country.objects.get(usd_value=first_['country_from'])
		c_out = Country.objects.get(usd_value=first_['country_to'])

		tracking_obj = Tracking.objects.create(
			currency_in=c_in,
			currency_out=c_out,
			amount_in=step_1['amount'],
			amount_out=float(step_1['amount'])*(splitData(c_in.usd_value)/splitData(c_out.usd_value)),


			name_sender = step_1['firstname'],
			phone_sender = step_1['number'],

			name_reciever = step_2['firstname'],
			phone_reciever = step_2['number'],
			alt_phone_reciever = step_2['alt_number'],
			)
		tracking_obj.save()
		if(tracking_obj):
			messages.success(request, "Vos informations ont été envoyées avec success. Notre équipe se charge de la suite. N'hésitez surtout pas à nous contacter sur whatsapp si vous avez des questions")
			return redirect(index)
		else:
			messages.error(request,"Une erreur de saisie est survenue, veuillez réessayer")
			return redirect(index)
			
	return render(request, 'steps_forms.html', locals())



@login_required(login_url=('login'))
def AdminView(request):
	adm = True
	template = 'admin.html'
	countries = Country.objects.all()
	if 'addCurrency' in request.POST:
		return redirect('addCurrency')

	return render(request, template, locals())

@login_required(login_url=('login'))
def addCurrency(request):
	template = 'forms.html'
	form = CountryForm(request.POST or None, request.FILES)
	if(request.method =="POST"):
		if(form.is_valid()):
			form.save()
			return redirect('admin')
	form = CountryForm()
	return render(request, template, locals())

def disconnect(request):
	logout(request)
	return redirect("home")


def Connexion(request):
	template_name = 'forms.html'
	connexion_form = ConnexionForm(request.POST)
	if connexion_form.is_valid():
		username = connexion_form.cleaned_data['username']
		password = connexion_form.cleaned_data['password']
		user = authenticate(username=username, password=password)
		if user:  # Si l'objet renvoyé n'est pas None
			login(request, user)
			messages.success(request, "You're now connected!")
			return redirect('admin')
		else:
			messages.error(request,request, "logins incorrect!")
	connexion_form = ConnexionForm()
	return render(request, template_name, locals())

class Register(View):
	template_name = 'forms.html'

	def post(self, request, *args, **kwargs):
		
		register_form = RegisterForm(request.POST)
		if register_form.is_valid():
			try:
				username = register_form.cleaned_data['username']
				firstname = register_form.cleaned_data['firstname']
				lastname = register_form.cleaned_data['lastname']
				password = register_form.cleaned_data['password']
				password2 = register_form.cleaned_data['password2']
				phone = register_form.cleaned_data['phone']
				if (password == password2):
					user = User.objects.create_user(
					username=username,
					password=password)
					user.first_name, user.last_name = firstname, lastname
					user.save()
					profile = Profile(user=user, phone=phone)
					profile.save()
					messages.success(request, "Hello "+username+", you are registered successfully!")
					if user:
						login(request, user)
						return redirect("cv-admin")
				else:
					register_form = RegisterForm()
			except Exception as e:
				messages.error(request, str(e))
		register_form = RegisterForm()
		return render(request, self.template_name, locals())

@login_required(login_url='/login/')
def update(request, country_id):
	country = Country.objects.get(id=country_id)

	form = CountryForm(request.POST,  instance=country)
	if(request.method == 'POST'):
		if(form.is_valid()):
			form.save()
			return redirect('admin')
	form = CountryForm(instance=country)
	return render(request, "forms.html", locals())


